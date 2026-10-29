//! Downloads: original files from Jellyfin into a folder of your videos,
//! with everything a details page needs saved beside them, so they play
//! and show offline.
//!
//! The list survives everything: it lives in `downloads.json` (written
//! atomically), a download in progress writes to `name.part`, and an
//! interrupted one (network, sleep, crash, reboot) resumes where it stopped
//! with an HTTP Range request. Jellyfin sends no ETag and ignores If-Range,
//! so a resume compares the file's size and Last-Modified with what the
//! first request saw, and starts over when the file changed on the server.
//!
//! One download runs at a time; the rest wait in order. Removing a finished
//! download moves its files to the desktop trash, never deletes them.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;
use tokio::sync::Notify;

use crate::app::App;
use crate::error::{self, Error, Result};
use crate::jellyfin::{require_id, valid_id};
use crate::library::{self, str_param, user_id};

/// Kept free beyond the file itself, so a download never fills the disk.
const SPARE: u64 = 512 * 1024 * 1024;
const PROGRESS_EVERY: Duration = Duration::from_millis(400);
const SAVE_EVERY: Duration = Duration::from_secs(5);
/// Names tried after the first one is taken: "Title [tag]", "Title [tag] (2)", …
const FALLBACKS: usize = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Queued,
    Downloading,
    Paused,
    Failed,
    Done,
    /// Finished once, but the file is gone (deleted in the file manager).
    Missing,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Entry {
    pub id: String,
    pub source_id: String,
    /// The card for this title (name, pictures, episode numbers), so lists
    /// draw without the server.
    pub card: Value,
    /// The folder the video sits in, and the video's file name.
    pub folder: String,
    pub file: String,
    /// Where this title's own metadata is (`.omafin/…`), and the show's.
    pub meta: String,
    pub series_meta: String,
    pub size: u64,
    pub bytes: u64,
    /// What the server said about the file the first time: a resume of a
    /// file with another size or date starts over.
    pub modified: String,
    pub state: State,
    pub error: String,
    pub added: u64,
    pub finished: u64,
    /// The metadata and pictures are saved.
    pub meta_saved: bool,
    /// Watched here while the server was out of reach, not told yet:
    /// { position, played, at } (seconds, bool, unix seconds).
    pub pending: Value,
    /// The disk the download was saved on (st_dev). A folder that is gone
    /// only counts as deleted while that disk is still there: an unplugged
    /// drive makes its folders vanish too, and must not forget downloads.
    pub device: u64,
    #[serde(skip)]
    pub speed: f64,
    #[serde(skip)]
    pub retry_at: Option<u64>,
    #[serde(skip)]
    pub attempts: u32,
}

impl Default for Entry {
    fn default() -> Self {
        Self {
            id: String::new(),
            source_id: String::new(),
            card: Value::Null,
            folder: String::new(),
            file: String::new(),
            meta: String::new(),
            series_meta: String::new(),
            size: 0,
            bytes: 0,
            modified: String::new(),
            state: State::Queued,
            error: String::new(),
            added: 0,
            finished: 0,
            meta_saved: false,
            pending: Value::Null,
            device: 0,
            speed: 0.0,
            retry_at: None,
            attempts: 0,
        }
    }
}

impl Entry {
    pub fn video(&self) -> PathBuf {
        Path::new(&self.folder).join(&self.file)
    }

    fn part(&self) -> PathBuf {
        Path::new(&self.folder).join(format!("{}.part", self.file))
    }

    fn unfinished(&self) -> bool {
        matches!(self.state, State::Queued | State::Downloading | State::Paused | State::Failed)
    }

    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "card": self.card,
            "state": self.state,
            "size": self.size,
            "bytes": self.bytes,
            "speed": self.speed.round(),
            "error": self.error,
            "path": self.video(),
            "retrying": self.retry_at.is_some(),
            "added": self.added,
            "finished": self.finished,
        })
    }
}

pub struct Downloads {
    entries: Mutex<Vec<Entry>>,
    index: PathBuf,
    wake: Notify,
    /// Watches the download folders, so a deletion in the file manager is
    /// noticed at once (inotify; nothing runs while nothing changes).
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
    /// Pokes the watch to look again (after a download makes new folders).
    rewatch: Mutex<Option<tokio::sync::mpsc::UnboundedSender<()>>>,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl Downloads {
    pub fn load(index: PathBuf) -> Arc<Self> {
        let mut entries: Vec<Entry> = std::fs::read(&index)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        for e in entries.iter_mut() {
            // Whatever was running when the backend stopped carries on.
            if e.state == State::Downloading {
                e.state = State::Queued;
            }
            if e.unfinished() {
                e.bytes = std::fs::metadata(e.part()).map(|m| m.len()).unwrap_or(0);
            }
        }
        entries.retain(|e| valid_id(&e.id) && !e.folder.is_empty() && !e.file.is_empty());
        for e in &entries {
            tidy_metadata(&e.meta);
            tidy_metadata(&e.series_meta);
        }
        let downloads = Arc::new(Self { entries: Mutex::new(entries), index, wake: Notify::new(), watcher: Mutex::new(None), rewatch: Mutex::new(None) });
        let _ = downloads.check_files();
        downloads.save();
        downloads
    }

    fn save(&self) {
        let entries = self.entries.lock().unwrap().clone();
        if let Ok(bytes) = serde_json::to_vec_pretty(&entries) {
            if let Err(err) = crate::paths::write_private(&self.index, &bytes) {
                eprintln!("omafin: could not save the downloads list: {err}");
            }
        }
    }

    fn with<R>(&self, id: &str, f: impl FnOnce(&mut Entry) -> R) -> Option<R> {
        let mut entries = self.entries.lock().unwrap();
        entries.iter_mut().find(|e| e.id == id).map(f)
    }

    pub fn get(&self, id: &str) -> Option<Entry> {
        self.entries.lock().unwrap().iter().find(|e| e.id == id).cloned()
    }

    /// Finished downloads changed outside Omafin, in the file manager:
    /// - the video and its metadata both gone (the folder deleted): the
    ///   download is forgotten, it simply leaves Downloaded;
    /// - only the video gone: it stays, marked missing, to download again;
    /// - its disk not there (an unplugged drive): marked unavailable, and
    ///   back as it was when the drive returns. Nothing is forgotten then.
    /// Only a path that is certainly gone counts (`try_exists() == Ok(false)`).
    pub fn check_files(&self) -> Changes {
        let mut changes = Changes::default();
        let mut entries = self.entries.lock().unwrap();
        for e in entries.iter_mut() {
            if e.device == 0 {
                // Downloads from before disks were recorded: learn it while the folder is here.
                if let Some(dev) = Path::new(&e.folder).exists().then(|| device_of(Path::new(&e.folder))).flatten() {
                    e.device = dev;
                    changes.save = true;
                }
            }
            if !matches!(e.state, State::Done | State::Missing) {
                continue;
            }
            match e.video().try_exists() {
                Ok(true) => {
                    if e.state == State::Missing {
                        e.state = State::Done;
                        e.error.clear();
                        changes.changed.push(e.clone());
                    }
                }
                Ok(false) => {
                    let disk_here = e.device != 0 && device_of(Path::new(&e.folder)) == Some(e.device);
                    let meta_gone = matches!(Path::new(&e.meta).try_exists(), Ok(false));
                    if disk_here && meta_gone {
                        changes.forgotten.push(e.id.clone());
                        continue;
                    }
                    let why = if disk_here { "The downloaded file was removed" } else { "The drive with this download is not connected" };
                    if e.state != State::Missing || e.error != why {
                        e.state = State::Missing;
                        e.error = why.into();
                        changes.changed.push(e.clone());
                    }
                }
                Err(_) => {}
            }
        }
        if !changes.forgotten.is_empty() {
            entries.retain(|e| !changes.forgotten.contains(&e.id));
        }
        changes.save |= !changes.changed.is_empty() || !changes.forgotten.is_empty();
        changes
    }

    pub fn list(&self) -> Vec<Value> {
        self.entries.lock().unwrap().iter().map(Entry::to_json).collect()
    }
}

#[derive(Default)]
pub struct Changes {
    pub changed: Vec<Entry>,
    pub forgotten: Vec<String>,
    pub save: bool,
}

/// The disk a path is on: its own, or its nearest existing parent's (for a
/// path that is gone, the disk it would be on now).
fn device_of(path: &Path) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    let mut probe = path;
    loop {
        if let Ok(meta) = std::fs::metadata(probe) {
            return Some(meta.dev());
        }
        probe = probe.parent()?;
    }
}

/// Look at the files, tell the window what changed outside Omafin.
pub fn check_and_tell(app: &App) {
    let changes = app.downloads.check_files();
    if changes.save {
        app.downloads.save();
    }
    for e in &changes.changed {
        notify(app, e);
    }
    for id in &changes.forgotten {
        notify_removed(app, id);
    }
}

pub fn notify_entry(app: &App, entry: &Entry) {
    notify(app, entry)
}

fn notify(app: &App, entry: &Entry) {
    app.notifier.notify("downloads.changed", json!({ "entry": entry.to_json() }));
}

fn notify_removed(app: &App, id: &str) {
    app.notifier.notify("downloads.changed", json!({ "removed": id }));
}

// ---------------------------------------------------------------- names

/// A file or folder name from a title: no slashes, no control characters,
/// nothing that hides it or that other systems refuse, and not too long.
pub fn clean_name(raw: &str) -> String {
    let mut out = String::new();
    for c in raw.chars() {
        let c = match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => ' ',
            c if c.is_control() => ' ',
            c => c,
        };
        if c == ' ' && out.ends_with(' ') {
            continue;
        }
        out.push(c);
    }
    let trimmed: String = out.trim().trim_start_matches('.').trim().chars().take(120).collect();
    let trimmed = trimmed.trim_end_matches(['.', ' ']).to_string();
    if trimmed.is_empty() { "Untitled".into() } else { trimmed }
}

fn extension(disposition: Option<&str>, container: &str) -> String {
    let from_name = disposition
        .and_then(|d| d.split(';').find_map(|p| p.trim().strip_prefix("filename=")))
        .map(|n| n.trim_matches('"').to_string())
        .and_then(|n| n.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()));
    let ext = from_name.unwrap_or_else(|| container.split(',').next().unwrap_or("").trim().to_ascii_lowercase());
    if !ext.is_empty() && ext.len() <= 5 && ext.chars().all(|c| c.is_ascii_alphanumeric()) { ext } else { "mkv".into() }
}

/// Where a title goes inside the download folder: films in Movies/, episodes
/// by show and season under Shows/.
fn layout(root: &Path, card: &Value, ext: &str) -> (PathBuf, String, PathBuf, PathBuf) {
    let name = card["name"].as_str().unwrap_or("Untitled");
    if card["type"] == "Episode" {
        let series = clean_name(card["seriesName"].as_str().unwrap_or("Unknown show"));
        let season = card["parentIndex"].as_i64().unwrap_or(0);
        let index = card["index"].as_i64().unwrap_or(0);
        let show = root.join("Shows").join(&series);
        let folder = show.join(format!("Season {season:02}"));
        let stem = clean_name(&format!("S{season:02}E{index:02} - {name}"));
        let meta = folder.join(".omafin").join(&stem);
        (folder, format!("{stem}.{ext}"), meta, show.join(".omafin").join("series"))
    } else {
        // Some libraries already name a film "Title (2001)".
        let title = match card["year"].as_i64() {
            Some(year) if !name.trim_end().ends_with(&format!("({year})")) => clean_name(&format!("{name} ({year})")),
            _ => clean_name(name),
        };
        let folder = root.join("Movies").join(&title);
        let meta = folder.join(".omafin");
        (folder, format!("{title}.{ext}"), meta, PathBuf::new())
    }
}

// ---------------------------------------------------------------- space

/// Free space for an ordinary user on the filesystem holding `path` (or its
/// nearest existing parent).
pub fn free_space(path: &Path) -> Option<u64> {
    let mut probe = path.to_path_buf();
    while !probe.exists() {
        probe = probe.parent()?.to_path_buf();
    }
    let c = std::ffi::CString::new(probe.as_os_str().as_encoded_bytes()).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    Some(stat.f_bavail as u64 * stat.f_frsize as u64)
}

fn bytes_text(n: u64) -> String {
    let gb = n as f64 / 1e9;
    if gb >= 1.0 { format!("{gb:.1} GB") } else { format!("{:.0} MB", n as f64 / 1e6) }
}

fn root(app: &App) -> PathBuf {
    let dir = app.settings().downloads_dir;
    if dir.is_empty() { app.paths.default_downloads() } else { PathBuf::from(dir) }
}

/// The download folder, when Omafin has to make it, is the user's alone:
/// the names in it say what was downloaded. One that is already there
/// (chosen in Settings, or shared on purpose) is left as it is.
fn make_root(root: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    if root.try_exists()? {
        return Ok(());
    }
    if let Some(parent) = root.parent() {
        std::fs::create_dir_all(parent)?;
    }
    match std::fs::DirBuilder::new().mode(0o700).create(root) {
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        other => other,
    }
}

// ---------------------------------------------------------------- offline

impl Downloads {
    /// A finished download whose file is really there.
    pub fn playable(&self, id: &str) -> Option<Entry> {
        let entry = self.get(id)?;
        (entry.state == State::Done && matches!(entry.video().try_exists(), Ok(true))).then_some(entry)
    }

    fn all(&self) -> Vec<Entry> {
        self.entries.lock().unwrap().clone()
    }

    /// A saved picture for an item: its own (films, episodes), its show's,
    /// or a cast member's.
    pub fn local_image(&self, id: &str, kind: &str) -> Option<PathBuf> {
        let file = format!("{}.img", kind.to_ascii_lowercase());
        for e in self.all() {
            if e.id == id {
                let p = Path::new(&e.meta).join(&file);
                if p.exists() {
                    return Some(p);
                }
            }
            if e.card["seriesId"].as_str() == Some(id) && !e.series_meta.is_empty() {
                let p = Path::new(&e.series_meta).join(&file);
                if p.exists() {
                    return Some(p);
                }
            }
            if kind == "Primary" {
                let p = Path::new(&e.meta).join("people").join(format!("{id}.jpg"));
                if p.exists() {
                    return Some(p);
                }
            }
        }
        None
    }

    /// A saved subtitle track of a download.
    pub fn subtitle_file(&self, id: &str, index: i64) -> Option<PathBuf> {
        let entry = self.get(id)?;
        let dir = Path::new(&entry.meta).join("subtitles");
        std::fs::read_dir(&dir).ok()?.flatten().map(|f| f.path()).find(|p| {
            p.file_name().and_then(|n| n.to_str()).map(|n| n.starts_with(&format!("{index}.")) && n.ends_with(".vtt")).unwrap_or(false)
        })
    }

    pub fn item_json(entry: &Entry) -> Option<Value> {
        read_json(&Path::new(&entry.meta).join("item.json"))
    }

    /// Where a download was left: kept on its card, so lists and Resume
    /// work offline, and remembered for the server when it cannot be told.
    pub fn record_progress(&self, id: &str, position: f64, runtime: f64, told_server: bool) -> Option<Entry> {
        let played = runtime > 0.0 && position >= runtime * 0.9;
        let entry = self.with(id, |e| {
            let user = e.card["user"].as_object_mut();
            if let Some(user) = user {
                user.insert("played".into(), json!(played || user.get("played").and_then(|v| v.as_bool()).unwrap_or(false) && position < 1.0));
                user.insert("position".into(), if played || position < 1.0 { Value::Null } else { json!(position.round()) });
                user.insert("percent".into(), if played || runtime <= 0.0 { Value::Null } else { json!(position / runtime * 100.0) });
            }
            e.pending = if told_server { Value::Null } else { json!({ "position": position, "played": played, "at": now() }) };
            e.clone()
        });
        self.save();
        entry
    }
}

impl Downloads {
    /// What the server says about a download, learned while online: the card
    /// follows it, so the Downloaded list and Resume agree with other
    /// devices. A place not yet sent to the server stays, unless `mark` (a
    /// mark made just now, newer than that place).
    pub fn adopt_user(&self, id: &str, user: &Value, mark: bool) -> Option<Entry> {
        let entry = self
            .with(id, |e| {
                if e.pending.is_object() && !mark {
                    return None;
                }
                let card = e.card["user"].as_object_mut()?;
                let before = card.clone();
                for key in ["played", "position", "percent", "favorite"] {
                    if let Some(value) = user.get(key) {
                        card.insert(key.into(), value.clone());
                    }
                }
                let changed = *card != before || e.pending.is_object();
                e.pending = Value::Null;
                changed.then(|| e.clone())
            })
            .flatten()?;
        self.save();
        Some(entry)
    }
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// Downloaded episodes of a show, in order.
fn episodes_of(app: &App, series: &str) -> Vec<Entry> {
    let mut eps: Vec<Entry> = app
        .downloads
        .all()
        .into_iter()
        .filter(|e| e.card["seriesId"].as_str() == Some(series) && e.card["type"] == "Episode")
        .collect();
    eps.sort_by_key(|e| (e.card["parentIndex"].as_i64().unwrap_or(0), e.card["index"].as_i64().unwrap_or(0)));
    eps
}

/// A details page from what a download saved, for when the server is out
/// of reach: a film or an episode, or a show with downloaded episodes.
pub fn offline_details(app: &App, id: &str) -> Option<Value> {
    if let Some(entry) = app.downloads.get(id) {
        let item = Downloads::item_json(&entry)?;
        let mut out = library::details(&item, id);
        out["user"] = entry.card["user"].clone();
        out["offline"] = json!(true);
        return Some(out);
    }
    let eps = episodes_of(app, id);
    let first = eps.first()?;
    let series = read_json(&Path::new(&first.series_meta).join("item.json"))?;
    let mut out = library::details(&series, id);
    let unplayed = eps.iter().filter(|e| e.card["user"]["played"] != true).count();
    out["user"]["unplayed"] = json!(unplayed);
    out["nextUp"] = eps.iter().find(|e| e.card["user"]["played"] != true).map(|e| e.card.clone()).unwrap_or(Value::Null);
    out["offline"] = json!(true);
    Some(out)
}

/// The seasons of a show that have downloaded episodes.
pub fn offline_seasons(app: &App, series: &str) -> Vec<Value> {
    let mut seasons: Vec<Value> = Vec::new();
    for e in episodes_of(app, series) {
        let id = e.card["seasonId"].clone();
        if seasons.iter().any(|s| s["id"] == id) {
            continue;
        }
        let index = e.card["parentIndex"].clone();
        let mut season = json!({
            "id": id, "type": "Season", "isFolder": true,
            "name": e.card["seasonName"].as_str().map(String::from).unwrap_or_else(|| format!("Season {}", index)),
            "index": index, "seriesId": series, "seriesName": e.card["seriesName"],
            "images": { "primary": e.card["images"]["series"], "backdrop": e.card["images"]["backdrop"] },
            "user": { "played": false, "favorite": false },
        });
        let unplayed = episodes_of(app, series)
            .iter()
            .filter(|x| x.card["seasonId"] == season["id"] && x.card["user"]["played"] != true)
            .count();
        season["user"]["unplayed"] = json!(unplayed);
        seasons.push(season);
    }
    seasons
}

pub fn offline_episodes(app: &App, series: &str, season: &str) -> Vec<Value> {
    episodes_of(app, series)
        .into_iter()
        .filter(|e| season.is_empty() || e.card["seasonId"].as_str() == Some(season))
        .map(|e| e.card)
        .collect()
}

/// The downloaded episode after this one, if there is one.
pub fn offline_next(app: &App, id: &str, series: &str) -> Value {
    let eps = episodes_of(app, series);
    let at = eps.iter().position(|e| e.id == id);
    at.and_then(|i| eps.get(i + 1)).map(|e| e.card.clone()).unwrap_or(Value::Null)
}

/// Tell the server where downloads were left while it was out of reach,
/// unless it has heard of a later viewing since (another device wins then).
pub async fn sync_pending(app: &App) {
    let Ok(uid) = user_id(app) else { return };
    let pending: Vec<Entry> = app.downloads.all().into_iter().filter(|e| e.pending.is_object()).collect();
    for e in pending {
        let at = e.pending["at"].as_u64().unwrap_or(0);
        let server = app.jellyfin.get(&format!("/UserItems/{}/UserData?userId={uid}", e.id)).await;
        let Ok(server) = server else { return }; // still out of reach
        let server_at = server
            .get("LastPlayedDate")
            .and_then(|v| v.as_str())
            .and_then(|d| chrono::DateTime::parse_from_rfc3339(d).ok())
            .map(|d| d.timestamp() as u64)
            .unwrap_or(0);
        if server_at <= at {
            let played = e.pending["played"].as_bool().unwrap_or(false);
            let position = e.pending["position"].as_f64().unwrap_or(0.0);
            let stamp = chrono::DateTime::from_timestamp(at as i64, 0).map(|d| d.to_rfc3339()).unwrap_or_default();
            let body = json!({
                "PlaybackPositionTicks": if played { 0 } else { (position * crate::jellyfin::TICKS_PER_SECOND as f64) as i64 },
                "Played": played,
                "LastPlayedDate": stamp,
            });
            if app.jellyfin.post(&format!("/UserItems/{}/UserData?userId={uid}", e.id), body).await.is_err() {
                return;
            }
        }
        if let Some(entry) = app.downloads.with(&e.id, |x| {
            x.pending = Value::Null;
            x.clone()
        }) {
            notify(app, &entry);
        }
        app.downloads.save();
    }
}

/// The Downloaded library: films as they are, episodes gathered under their
/// show, sorted and filtered like any library.
pub async fn items(app: &App, params: &Value) -> Result<Value> {
    check_and_tell(app);
    let entries = app.downloads.all();
    let mut cards: Vec<(Value, u64)> = Vec::new();
    let mut shows: HashMap<String, (Value, u64, usize, usize)> = HashMap::new();
    for e in &entries {
        if e.card["type"] == "Episode" {
            let Some(series) = e.card["seriesId"].as_str().filter(|s| valid_id(s)) else { continue };
            let slot = shows.entry(series.to_string()).or_insert_with(|| {
                let card = read_json(&Path::new(&e.series_meta).join("item.json"))
                    .map(|s| library::card(&s))
                    .unwrap_or_else(|| json!({ "id": series, "type": "Series", "name": e.card["seriesName"], "images": { "primary": e.card["images"]["series"] }, "user": {} }));
                (card, e.added, 0, 0)
            });
            slot.1 = slot.1.max(e.added);
            slot.2 += 1;
            if e.card["user"]["played"] != true {
                slot.3 += 1;
            }
        } else {
            cards.push((e.card.clone(), e.added));
        }
    }
    for (_, (mut card, added, count, unplayed)) in shows {
        card["user"]["unplayed"] = json!(unplayed);
        card["user"]["played"] = json!(unplayed == 0);
        card["childCount"] = json!(count);
        cards.push((card, added));
    }
    let filters: Vec<String> = params
        .get("filters")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|f| f.as_str().map(String::from)).collect())
        .unwrap_or_default();
    cards.retain(|(c, _)| {
        filters.iter().all(|f| match f.as_str() {
            "played" => c["user"]["played"] == true,
            "unplayed" => c["user"]["played"] != true,
            "favorite" => c["user"]["favorite"] == true,
            "resumable" => c["user"]["position"].as_f64().unwrap_or(0.0) > 0.0,
            _ => true,
        })
    });
    let key = |c: &Value, f: &str| -> String {
        match f {
            "released" => c["premiere"].as_str().map(String::from).unwrap_or_else(|| format!("{:04}", c["year"].as_i64().unwrap_or(0))),
            "rating" => format!("{:08.3}", c["rating"].as_f64().unwrap_or(0.0)),
            "runtime" => format!("{:012}", c["runtime"].as_f64().unwrap_or(0.0) as i64),
            "played" => c["user"]["lastPlayed"].as_str().unwrap_or("").to_string(),
            _ => c["name"].as_str().unwrap_or("").to_lowercase(),
        }
    };
    let sort = str_param(params, "sort");
    match sort {
        "added" => cards.sort_by_key(|(_, added)| *added),
        "" | "name" | "random" => cards.sort_by_key(|(c, _)| key(c, "name")),
        other => cards.sort_by_key(|(c, _)| key(c, other)),
    }
    if params.get("descending").and_then(|v| v.as_bool()).unwrap_or(false) {
        cards.reverse();
    }
    let total = cards.len();
    Ok(json!({ "items": cards.into_iter().map(|(c, _)| c).collect::<Vec<_>>(), "total": total }))
}

// ---------------------------------------------------------------- RPC

pub async fn list(app: &App) -> Result<Value> {
    check_and_tell(app);
    let root = root(app);
    Ok(json!({
        "root": root,
        "free": free_space(&root),
        "entries": app.downloads.list(),
    }))
}

/// Queue one film or episode. Already downloaded or on its way: nothing
/// new happens. Failed, paused or missing: it is queued again.
pub async fn add(app: &App, params: &Value) -> Result<Value> {
    let id = require_id(str_param(params, "id"))?.to_string();
    let source = match str_param(params, "sourceId") {
        "" => None,
        s => Some(require_id(s)?.to_string()),
    };
    let entry = add_one(app, &id, source.as_deref(), 0).await?;
    app.downloads.wake.notify_one();
    Ok(entry.to_json())
}

/// Queue every episode of a season that is not downloaded yet, after one
/// check that they all fit.
pub async fn add_season(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let series = require_id(str_param(params, "seriesId"))?;
    let season = require_id(str_param(params, "seasonId"))?;
    let list = app
        .jellyfin
        .get(&format!("/Shows/{series}/Episodes?userId={uid}&seasonId={season}&fields=MediaSources"))
        .await?;
    let episodes: Vec<Value> = list.get("Items").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let mut wanted = Vec::new();
    let mut needed = 0u64;
    for e in &episodes {
        let Some(id) = e.get("Id").and_then(|v| v.as_str()).filter(|i| valid_id(i)) else { continue };
        if e.get("LocationType").and_then(|v| v.as_str()) == Some("Virtual") {
            continue; // listed by the server, but no file
        }
        if let Some(existing) = app.downloads.get(id) {
            if matches!(existing.state, State::Done | State::Downloading | State::Queued) {
                continue;
            }
        }
        needed += e.pointer("/MediaSources/0/Size").and_then(|v| v.as_u64()).unwrap_or(0);
        wanted.push(id.to_string());
    }
    let free = free_space(&root(app)).unwrap_or(u64::MAX);
    if needed + SPARE > free {
        return Err(Error::invalid(format!(
            "This season needs {} and {} is free",
            bytes_text(needed),
            bytes_text(free)
        )));
    }
    let mut added = 0;
    for id in &wanted {
        // The season as a whole was checked; each episode then only needs itself.
        add_one(app, id, None, needed).await?;
        added += 1;
    }
    app.downloads.wake.notify_one();
    Ok(json!({ "added": added, "skipped": episodes.len() - added }))
}

async fn add_one(app: &App, id: &str, source: Option<&str>, season_checked: u64) -> Result<Entry> {
    if let Some(existing) = app.downloads.get(id) {
        if matches!(existing.state, State::Done | State::Downloading | State::Queued) {
            return Ok(existing);
        }
        // Failed, paused or missing: try again, keeping what is on disk.
        let entry = app.downloads.with(id, |e| {
            // A missing file is downloaded whole again; a partial one resumes.
            if e.state == State::Missing || !matches!(e.part().try_exists(), Ok(true)) {
                e.bytes = 0;
            }
            e.state = State::Queued;
            e.error.clear();
            e.retry_at = None;
            e.attempts = 0;
            e.clone()
        });
        app.downloads.save();
        if let Some(entry) = &entry {
            notify(app, entry);
        }
        return entry.ok_or_else(|| Error::internal("The download vanished"));
    }
    let uid = user_id(app)?;
    let item = app.jellyfin.get(&format!("/Items/{id}?userId={uid}")).await?;
    if item.get("MediaType").and_then(|v| v.as_str()) != Some("Video") {
        return Err(Error::invalid("Omafin downloads films and episodes"));
    }
    if item.get("CanDownload").and_then(|v| v.as_bool()) == Some(false) {
        return Err(Error::new(error::FORBIDDEN, "Your Jellyfin account may not download this"));
    }
    let sources = item.get("MediaSources").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let chosen = sources
        .iter()
        .find(|s| source.map(|want| s["Id"].as_str() == Some(want)).unwrap_or(true))
        .cloned()
        .ok_or_else(|| Error::invalid("That video has no file to download"))?;
    let source_id = chosen["Id"].as_str().filter(|s| valid_id(s)).unwrap_or(id).to_string();
    let size = chosen.get("Size").and_then(|v| v.as_u64()).unwrap_or(0);
    let root = root(app);
    if season_checked == 0 {
        let free = free_space(&root).unwrap_or(u64::MAX);
        if size + SPARE > free {
            return Err(Error::invalid(format!("This needs {} and {} is free", bytes_text(size), bytes_text(free))));
        }
    }
    let card = library::card(&item);
    let ext = extension(None, chosen["Container"].as_str().unwrap_or("mkv"));
    let (mut folder, mut file, mut meta, series_meta) = layout(&root, &card, &ext);
    // Two titles that clean to the same name keep apart. A film owns its
    // whole folder (removing it trashes the folder), so a second film of the
    // same name gets a folder of its own; episodes share a season folder and
    // only need their own file name. What is already on disk counts too: a
    // download folder can be a library of the person's own, whose files
    // Omafin must never replace or trash. A fallback name is checked the same
    // way as the first one: "Title [tag]" can be the person's too.
    {
        let entries = app.downloads.entries.lock().unwrap();
        let tag = &id[..8];
        let taken = |p: &Path| !matches!(p.try_exists(), Ok(false));
        let fallbacks = std::iter::once(String::new()).chain((1..=FALLBACKS).map(|n| if n == 1 { format!(" [{tag}]") } else { format!(" [{tag}] ({n})") }));
        let mut free = false;
        if card["type"] == "Episode" {
            let stem = file.trim_end_matches(&format!(".{ext}")).to_string();
            for suffix in fallbacks {
                let try_file = format!("{stem}{suffix}.{ext}");
                let try_meta = meta.with_file_name(format!("{stem}{suffix}"));
                let on_disk = taken(&folder.join(&try_file)) || taken(&folder.join(format!("{try_file}.part"))) || taken(&try_meta);
                if !on_disk && !entries.iter().any(|e| e.id != id && e.folder == folder.to_string_lossy() && e.file == try_file) {
                    (file, meta, free) = (try_file, try_meta, true);
                    break;
                }
            }
        } else {
            let base = folder.file_name().and_then(|n| n.to_str()).unwrap_or("Untitled").to_string();
            for suffix in fallbacks {
                let name = format!("{base}{suffix}");
                let try_folder = folder.with_file_name(&name);
                if !taken(&try_folder) && !entries.iter().any(|e| e.id != id && e.folder == try_folder.to_string_lossy()) {
                    meta = try_folder.join(".omafin");
                    file = format!("{name}.{ext}");
                    (folder, free) = (try_folder, true);
                    break;
                }
            }
        }
        if !free {
            return Err(Error::invalid("The download folder already holds too many files of that name"));
        }
    }
    let entry = Entry {
        id: id.to_string(),
        source_id,
        card,
        folder: folder.to_string_lossy().into_owned(),
        file,
        meta: meta.to_string_lossy().into_owned(),
        series_meta: series_meta.to_string_lossy().into_owned(),
        size,
        state: State::Queued,
        added: now(),
        device: device_of(&folder).unwrap_or(0),
        ..Default::default()
    };
    app.downloads.entries.lock().unwrap().push(entry.clone());
    app.downloads.save();
    notify(app, &entry);
    Ok(entry)
}

pub async fn pause(app: &App, params: &Value) -> Result<Value> {
    let id = require_id(str_param(params, "id"))?;
    let entry = app
        .downloads
        .with(id, |e| {
            if matches!(e.state, State::Queued | State::Downloading) {
                e.state = State::Paused;
                e.retry_at = None;
                e.speed = 0.0;
            }
            e.clone()
        })
        .ok_or_else(|| Error::invalid("That is not being downloaded"))?;
    app.downloads.save();
    notify(app, &entry);
    Ok(entry.to_json())
}

pub async fn resume(app: &App, params: &Value) -> Result<Value> {
    let id = require_id(str_param(params, "id"))?;
    let entry = app
        .downloads
        .with(id, |e| {
            if matches!(e.state, State::Paused | State::Failed) {
                e.state = State::Queued;
                e.error.clear();
                e.retry_at = None;
                e.attempts = 0;
            }
            e.clone()
        })
        .ok_or_else(|| Error::invalid("That is not being downloaded"))?;
    app.downloads.save();
    app.downloads.wake.notify_one();
    notify(app, &entry);
    Ok(entry.to_json())
}

/// Stop an unfinished download and throw its partial file away.
pub async fn cancel(app: &App, params: &Value) -> Result<Value> {
    let id = require_id(str_param(params, "id"))?;
    let entry = app.downloads.get(id).ok_or_else(|| Error::invalid("That is not being downloaded"))?;
    if !entry.unfinished() {
        return Err(Error::invalid("That download is finished; delete it instead"));
    }
    app.downloads.entries.lock().unwrap().retain(|e| e.id != id);
    app.downloads.save();
    let _ = std::fs::remove_file(entry.part());
    tidy(app, &entry);
    notify_removed(app, id);
    Ok(json!(true))
}

/// Move a finished (or missing) download's files to the desktop trash.
pub async fn remove(app: &App, params: &Value) -> Result<Value> {
    let id = require_id(str_param(params, "id"))?;
    let entry = app.downloads.get(id).ok_or_else(|| Error::invalid("That is not downloaded"))?;
    if entry.unfinished() {
        return Err(Error::invalid("That download is not finished; cancel it instead"));
    }
    let root = PathBuf::from(&entry.folder);
    let mut trashed = Vec::new();
    if entry.card["type"] != "Episode" && only_ours(&entry) {
        // A film's folder that holds only that film and its metadata goes whole.
        trashed.push(move_to_trash(&root).map_err(|e| Error::internal(format!("Could not move to the trash: {e}")))?);
    } else {
        // Episodes share their season folder, and a film's folder can have
        // gained someone's files: only the video, then its own metadata.
        for path in [entry.video(), PathBuf::from(&entry.meta)] {
            if matches!(path.try_exists(), Ok(true)) {
                trashed.push(move_to_trash(&path).map_err(|e| Error::internal(format!("Could not move to the trash: {e}")))?);
            }
        }
    }
    app.downloads.entries.lock().unwrap().retain(|e| e.id != id);
    app.downloads.save();
    tidy(app, &entry);
    notify_removed(app, id);
    Ok(json!({ "trashed": trashed }))
}

/// The download's folder is there and holds nothing but what Omafin wrote:
/// the video, its `.part` file and the `.omafin` metadata. Anything else, or
/// a folder that cannot be read, counts as someone's.
fn only_ours(entry: &Entry) -> bool {
    let ours = [entry.file.clone(), format!("{}.part", entry.file), ".omafin".to_string()];
    let Ok(mut dir) = std::fs::read_dir(&entry.folder) else { return false };
    dir.all(|e| e.is_ok_and(|e| ours.iter().any(|o| e.file_name() == o.as_str())))
}

/// Remove folders Omafin made that are now empty, and a show's metadata
/// once none of its episodes are left. Never anything with a file in it
/// that Omafin did not write.
fn tidy(app: &App, entry: &Entry) {
    let meta = PathBuf::from(&entry.meta);
    if entry.card["type"] == "Episode" {
        let _ = std::fs::remove_dir_all(&meta);
        let series_id = entry.card["seriesId"].as_str().unwrap_or("");
        let others = app.downloads.entries.lock().unwrap().iter().any(|e| e.card["seriesId"].as_str() == Some(series_id));
        if !others && !entry.series_meta.is_empty() {
            let _ = std::fs::remove_dir_all(&entry.series_meta);
        }
    } else if entry.unfinished() {
        let _ = std::fs::remove_dir_all(&meta);
    }
    // Empty folders up to the download root.
    let stop = root(app);
    let mut dir = Some(PathBuf::from(&entry.folder));
    while let Some(d) = dir {
        if d == stop || !d.starts_with(&stop) {
            break;
        }
        for inner in [d.join(".omafin")] {
            let _ = std::fs::remove_dir(&inner);
        }
        if std::fs::remove_dir(&d).is_err() {
            break;
        }
        dir = d.parent().map(Path::to_path_buf);
    }
}

/// Move a file or folder to the desktop trash (the freedesktop.org layout
/// every file manager reads), so a removed download can be put back.
pub fn move_to_trash(path: &Path) -> std::io::Result<PathBuf> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| crate::paths::home().join(".local/share"))
        .join("Trash");
    let files = base.join("files");
    let info = base.join("info");
    // The trash is the user's alone (the spec asks for 0700): the names in it,
    // and the paths in its .trashinfo files, say what was there.
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&files)?;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&info)?;
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("video").to_string();
    let mut target = files.join(&name);
    let mut n = 1;
    while target.exists() || info.join(format!("{}.trashinfo", target.file_name().unwrap().to_string_lossy())).exists() {
        target = files.join(format!("{name} ({n})"));
        n += 1;
    }
    let target_name = target.file_name().and_then(|n| n.to_str()).unwrap_or(&name).to_string();
    let absolute = std::fs::canonicalize(path)?;
    const PATH_SET: &percent_encoding::AsciiSet =
        &percent_encoding::NON_ALPHANUMERIC.remove(b'/').remove(b'-').remove(b'_').remove(b'.').remove(b'~');
    let encoded = percent_encoding::utf8_percent_encode(&absolute.to_string_lossy(), PATH_SET).to_string();
    let stamp = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S");
    let info_file = info.join(format!("{target_name}.trashinfo"));
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&info_file)?;
        f.write_all(format!("[Trash Info]\nPath={encoded}\nDeletionDate={stamp}\n").as_bytes())?;
    }
    // Only a move: a download on another drive than the trash is refused
    // rather than copied (and never deleted outright).
    if let Err(err) = std::fs::rename(path, &target) {
        let _ = std::fs::remove_file(&info_file);
        return Err(err);
    }
    Ok(target)
}

// ---------------------------------------------------------------- worker

/// Runs for the life of the backend: takes the first queued download,
/// downloads it, and waits for more.
/// The download folder of an entry: the folder that holds Movies/ and Shows/.
fn root_of(entry: &Entry) -> Option<PathBuf> {
    let up = if entry.card["type"] == "Episode" { 3 } else { 2 };
    Path::new(&entry.folder).ancestors().nth(up).map(Path::to_path_buf)
}

/// Watch every download folder in use (the current one, and older ones that
/// still hold downloads) for files deleted or put back outside Omafin.
pub fn rewatch(app: &Arc<App>, tx: &tokio::sync::mpsc::UnboundedSender<()>) {
    let mut roots: Vec<PathBuf> = vec![root(app)];
    for e in app.downloads.all() {
        if let Some(r) = root_of(&e) {
            if !roots.contains(&r) {
                roots.push(r);
            }
        }
    }
    let tx = tx.clone();
    let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(event) = res {
            use notify::EventKind;
            if matches!(event.kind, EventKind::Remove(_) | EventKind::Create(_) | EventKind::Modify(notify::event::ModifyKind::Name(_))) {
                let _ = tx.send(());
            }
        }
    });
    let Ok(mut watcher) = watcher else { return };
    use notify::Watcher;
    for r in roots.iter().filter(|r| r.is_dir()) {
        let _ = watcher.watch(r, notify::RecursiveMode::Recursive);
    }
    *app.downloads.watcher.lock().unwrap() = Some(watcher);
}

pub fn start(app: Arc<App>) {
    // Notice files deleted (or put back) in the file manager while running:
    // the watcher says something changed; a moment later (a folder deletion
    // is many events) the files are looked at once. A slow look every ten
    // minutes covers what inotify cannot see, like a drive plugged back in.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    rewatch(&app, &tx);
    let watched = app.clone();
    let rewatch_tx = tx.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                got = rx.recv() => {
                    if got.is_none() { return; }
                    tokio::time::sleep(Duration::from_millis(700)).await;
                    while rx.try_recv().is_ok() {}
                }
                _ = tokio::time::sleep(Duration::from_secs(600)) => {}
            }
            let app = watched.clone();
            let _ = tokio::task::spawn_blocking(move || check_and_tell(&app)).await;
            // New folders (the first download, a new download folder) join the watch.
            rewatch(&watched, &rewatch_tx);
        }
    });
    let (nudge, app_for_add) = (tx, app.clone());
    *app_for_add.downloads.rewatch.lock().unwrap() = Some(nudge);
    tokio::spawn(async move {
        loop {
            let next = {
                let entries = app.downloads.entries.lock().unwrap();
                let t = now();
                entries
                    .iter()
                    .find(|e| e.state == State::Queued && e.retry_at.map(|r| r <= t).unwrap_or(true))
                    .map(|e| e.id.clone())
            };
            let Some(id) = next else {
                // Wake for a new download, or the next retry.
                let soonest = app.downloads.entries.lock().unwrap().iter().filter_map(|e| e.retry_at).min();
                let wait = soonest.map(|r| Duration::from_secs(r.saturating_sub(now()).max(1))).unwrap_or(Duration::from_secs(3600));
                tokio::select! {
                    _ = app.downloads.wake.notified() => {}
                    _ = tokio::time::sleep(wait) => {}
                }
                continue;
            };
            run(&app, &id).await;
        }
    });
}

enum Outcome {
    Done,
    /// Stopped by a person (paused, cancelled, removed).
    Stopped,
    /// Try again later, keeping what is on disk.
    Retry(String),
    /// Stop until a person retries.
    Fail(String),
    /// Stop with the partial file kept (disk full).
    Pause(String),
}

async fn run(app: &Arc<App>, id: &str) {
    let Some(entry) = app.downloads.with(id, |e| {
        e.state = State::Downloading;
        e.error.clear();
        e.retry_at = None;
        e.clone()
    }) else {
        return;
    };
    notify(app, &entry);
    let outcome = transfer(app, &entry).await;
    let updated = app.downloads.with(id, |e| {
        e.speed = 0.0;
        match &outcome {
            Outcome::Done => {
                e.state = State::Done;
                e.finished = now();
                e.attempts = 0;
                e.device = device_of(&e.video()).unwrap_or(e.device);
            }
            Outcome::Stopped => {}
            Outcome::Retry(why) => {
                if e.state == State::Downloading {
                    e.attempts += 1;
                    if e.attempts > 8 {
                        e.state = State::Failed;
                        e.error = why.clone();
                    } else {
                        let wait = [2u64, 5, 15, 30, 60, 120, 300, 600][(e.attempts as usize - 1).min(7)];
                        e.state = State::Queued;
                        e.error = format!("{why}; trying again in {wait} s");
                        e.retry_at = Some(now() + wait);
                    }
                }
            }
            Outcome::Fail(why) => {
                e.state = State::Failed;
                e.error = why.clone();
            }
            Outcome::Pause(why) => {
                e.state = State::Paused;
                e.error = why.clone();
            }
        }
        e.clone()
    });
    app.downloads.save();
    if let Some(entry) = updated {
        notify(app, &entry);
    }
    // A finished download made folders the watch should cover.
    if let Some(tx) = app.downloads.rewatch.lock().unwrap().as_ref() {
        let _ = tx.send(());
    }
}

/// Still wanted? A pause, cancel or removal changes the entry's state.
fn wanted(app: &App, id: &str) -> bool {
    app.downloads.get(id).map(|e| e.state == State::Downloading).unwrap_or(false)
}

async fn transfer(app: &Arc<App>, entry: &Entry) -> Outcome {
    let folder = PathBuf::from(&entry.folder);
    let top = root(app);
    if folder.starts_with(&top) {
        if let Err(err) = make_root(&top) {
            return Outcome::Fail(format!("Could not make the folder {}: {err}", top.display()));
        }
    }
    if let Err(err) = std::fs::create_dir_all(&folder) {
        return Outcome::Fail(format!("Could not make the folder {}: {err}", folder.display()));
    }
    if !entry.meta_saved {
        match save_metadata(app, entry).await {
            Ok(()) => {
                app.downloads.with(&entry.id, |e| e.meta_saved = true);
            }
            Err(err) if err.code == error::NETWORK => return Outcome::Retry(err.message),
            // Pictures and subtitles are extras; the film itself still comes.
            Err(err) => eprintln!("omafin: download metadata for {}: {err}", entry.id),
        }
    }
    let part = entry.part();
    let mut have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if entry.size > 0 {
        let free = free_space(&folder).unwrap_or(u64::MAX);
        if entry.size.saturating_sub(have) + SPARE / 4 > free {
            return Outcome::Pause(format!("Not enough space: {} more needed, {} free", bytes_text(entry.size - have), bytes_text(free)));
        }
    }
    let mut headers = Vec::new();
    if have > 0 {
        headers.push(("Range", format!("bytes={have}-")));
    }
    let response = match app.jellyfin.raw(&format!("/Items/{}/Download", entry.id), &headers).await {
        Ok(r) => r,
        Err(err) => {
            return match err.code {
                error::NETWORK | error::SERVER => Outcome::Retry(err.message),
                error::NOT_FOUND => Outcome::Fail("The file is no longer on the server".into()),
                error::FORBIDDEN => Outcome::Fail("Your Jellyfin account may not download this".into()),
                error::UNAUTHORIZED => Outcome::Fail(err.message),
                error::NOT_CONFIGURED => Outcome::Retry("Not signed in".into()),
                _ => Outcome::Retry(err.message),
            };
        }
    };
    let status = response.status().as_u16();
    let modified = response.headers().get("last-modified").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    let range_total = response
        .headers()
        .get("content-range")
        .and_then(|v| v.to_str().ok())
        .and_then(|r| r.rsplit('/').next())
        .and_then(|t| t.parse::<u64>().ok());
    let range_start = response
        .headers()
        .get("content-range")
        .and_then(|v| v.to_str().ok())
        .and_then(|r| r.strip_prefix("bytes "))
        .and_then(|r| r.split('-').next())
        .and_then(|s| s.parse::<u64>().ok());
    let total = match status {
        206 => range_total,
        _ => response.content_length(),
    }
    .unwrap_or(entry.size);
    // The file changed on the server since the first part: start over.
    let changed = have > 0
        && ((!entry.modified.is_empty() && !modified.is_empty() && modified != entry.modified)
            || (entry.size > 0 && total != entry.size));
    let restart = status == 200 || changed || (status == 206 && range_start != Some(have));
    if restart && have > 0 {
        if changed && status == 206 {
            // Ask again from the beginning, for the new file.
            let _ = std::fs::remove_file(&part);
            app.downloads.with(&entry.id, |e| {
                e.bytes = 0;
                e.size = 0;
                e.modified.clear();
            });
            return Outcome::Retry("The file changed on the server; starting over".into());
        }
        have = 0;
    }
    app.downloads.with(&entry.id, |e| {
        e.size = total;
        e.bytes = have;
        if !modified.is_empty() {
            e.modified = modified.clone();
        }
    });
    // Never through a link someone planted where the .part file goes.
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new().create(true).write(true).truncate(have == 0).custom_flags(libc::O_NOFOLLOW).open(&part)
    };
    let file = match file {
        Ok(f) => f,
        Err(err) => return Outcome::Fail(format!("Could not write {}: {err}", part.display())),
    };
    let mut file = tokio::fs::File::from_std(file);
    if have > 0 {
        use tokio::io::AsyncSeekExt;
        if let Err(err) = file.seek(std::io::SeekFrom::Start(have)).await {
            return Outcome::Fail(format!("Could not resume {}: {err}", part.display()));
        }
    }
    let mut stream = response.bytes_stream();
    let mut last_progress = Instant::now();
    let mut last_save = Instant::now();
    let mut window_bytes = 0u64;
    let mut window_start = Instant::now();
    let mut speed = 0.0f64;
    loop {
        let chunk = match tokio::time::timeout(Duration::from_secs(60), stream.next()).await {
            Ok(Some(Ok(chunk))) => chunk,
            Ok(Some(Err(_))) | Err(_) => {
                let _ = file.flush().await;
                return Outcome::Retry("The connection to the server dropped".into());
            }
            Ok(None) => break,
        };
        if let Err(err) = file.write_all(&chunk).await {
            let _ = file.flush().await;
            if err.raw_os_error() == Some(libc::ENOSPC) {
                return Outcome::Pause("The disk is full; free some space and resume".into());
            }
            return Outcome::Fail(format!("Could not write the file: {err}"));
        }
        have += chunk.len() as u64;
        window_bytes += chunk.len() as u64;
        if last_progress.elapsed() >= PROGRESS_EVERY {
            let elapsed = window_start.elapsed().as_secs_f64().max(0.001);
            let instant = window_bytes as f64 / elapsed;
            speed = if speed == 0.0 { instant } else { speed * 0.7 + instant * 0.3 };
            window_bytes = 0;
            window_start = Instant::now();
            last_progress = Instant::now();
            if !wanted(app, &entry.id) {
                let _ = file.flush().await;
                return Outcome::Stopped;
            }
            let snapshot = app.downloads.with(&entry.id, |e| {
                e.bytes = have;
                e.speed = speed;
                e.attempts = 0; // progress: the next failure starts the waits over
                e.clone()
            });
            if let Some(s) = snapshot {
                notify(app, &s);
            }
            if last_save.elapsed() >= SAVE_EVERY {
                app.downloads.save();
                last_save = Instant::now();
            }
        }
    }
    if let Err(err) = file.sync_all().await {
        return Outcome::Retry(format!("Could not finish writing: {err}"));
    }
    drop(file);
    app.downloads.with(&entry.id, |e| e.bytes = have);
    if !wanted(app, &entry.id) {
        return Outcome::Stopped;
    }
    if total > 0 && have < total {
        return Outcome::Retry("The server stopped sending before the end".into());
    }
    if total > 0 && have > total {
        let _ = std::fs::remove_file(&part);
        app.downloads.with(&entry.id, |e| e.bytes = 0);
        return Outcome::Retry("The file came out larger than the server said; starting over".into());
    }
    // A file that appeared there meanwhile is someone's; never replace it.
    match rename_noreplace(&part, &entry.video()) {
        Ok(()) => Outcome::Done,
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            Outcome::Fail(format!("{} is already there; Omafin will not replace it", entry.video().display()))
        }
        Err(err) => Outcome::Fail(format!("Could not finish the file: {err}")),
    }
}

/// Rename that refuses to replace what is at `to`, in one step
/// (RENAME_NOREPLACE), so nothing can appear between a check and the move.
/// A filesystem without it (some network and FAT drives say EINVAL) gets a
/// check just before a plain rename.
fn rename_noreplace(from: &Path, to: &Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let c = |p: &Path| std::ffi::CString::new(p.as_os_str().as_bytes()).map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput));
    let (src, dst) = (c(from)?, c(to)?);
    if unsafe { libc::renameat2(libc::AT_FDCWD, src.as_ptr(), libc::AT_FDCWD, dst.as_ptr(), libc::RENAME_NOREPLACE) } == 0 {
        return Ok(());
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() != Some(libc::EINVAL) {
        return Err(err);
    }
    if !matches!(to.try_exists(), Ok(false)) {
        return Err(std::io::ErrorKind::AlreadyExists.into());
    }
    std::fs::rename(from, to)
}

/// The item, its pictures, its text subtitles and (for an episode) its
/// show, saved beside the video for the Downloaded view and offline use.
async fn save_metadata(app: &App, entry: &Entry) -> Result<()> {
    let uid = user_id(app)?;
    let meta = PathBuf::from(&entry.meta);
    private_dir(&meta)?;
    let item = app.jellyfin.get(&format!("/Items/{}?userId={uid}", entry.id)).await?;
    write_json(&meta.join("item.json"), &item)?;
    save_images(app, &item, &meta).await;
    // Intros and credits, for Skip offline.
    if let Ok(segments) = app.jellyfin.get(&format!("/MediaSegments/{}", entry.id)).await {
        let _ = write_json(&meta.join("segments.json"), &segments);
    }
    // Every text subtitle track, as the window draws them.
    let subs = meta.join("subtitles");
    let streams = item
        .pointer("/MediaSources")
        .and_then(|v| v.as_array())
        .and_then(|a| a.iter().find(|s| s["Id"].as_str() == Some(&entry.source_id)).or_else(|| a.first()))
        .and_then(|s| s.get("MediaStreams"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    for s in streams.iter().filter(|s| s["Type"] == "Subtitle" && s["IsTextSubtitleStream"] == true) {
        let Some(index) = s["Index"].as_i64() else { continue };
        let path = format!("/Videos/{}/{}/Subtitles/{index}/0/Stream.vtt", entry.id, entry.source_id);
        if let Ok(response) = app.jellyfin.raw(&path, &[]).await {
            if let Ok(bytes) = response.bytes().await {
                std::fs::create_dir_all(&subs)?;
                let lang = clean_name(s["Language"].as_str().unwrap_or("und"));
                std::fs::write(subs.join(format!("{index}.{lang}.vtt")), &bytes)?;
            }
        }
    }
    // People's pictures, small, for the cast row.
    let people = meta.join("people");
    for p in item.get("People").and_then(|v| v.as_array()).cloned().unwrap_or_default().iter().take(20) {
        let (Some(pid), Some(tag)) = (p["Id"].as_str().filter(|i| valid_id(i)), p["PrimaryImageTag"].as_str()) else { continue };
        let _ = save_image(app, &format!("/Items/{pid}/Images/Primary?tag={tag}&fillWidth=240&quality=85"), &people.join(format!("{pid}.jpg"))).await;
    }
    if !entry.series_meta.is_empty() {
        let series_meta = PathBuf::from(&entry.series_meta);
        if !series_meta.join("item.json").exists() {
            if let Some(series_id) = item.get("SeriesId").and_then(|v| v.as_str()).filter(|i| valid_id(i)) {
                private_dir(&series_meta)?;
                let series = app.jellyfin.get(&format!("/Items/{series_id}?userId={uid}")).await?;
                write_json(&series_meta.join("item.json"), &series)?;
                save_images(app, &series, &series_meta).await;
            }
        }
    }
    Ok(())
}

async fn save_images(app: &App, item: &Value, dir: &Path) {
    let id = item["Id"].as_str().unwrap_or("");
    if !valid_id(id) {
        return;
    }
    let mut wanted: HashMap<&str, String> = HashMap::new();
    for (kind, width) in [("Primary", 600), ("Thumb", 960), ("Logo", 800)] {
        if let Some(tag) = item.pointer(&format!("/ImageTags/{kind}")).and_then(|v| v.as_str()) {
            wanted.insert(kind, format!("/Items/{id}/Images/{kind}?tag={tag}&fillWidth={width}&quality=90"));
        }
    }
    if let Some(tag) = item.pointer("/BackdropImageTags/0").and_then(|v| v.as_str()) {
        wanted.insert("Backdrop", format!("/Items/{id}/Images/Backdrop?tag={tag}&fillWidth=1920&quality=85"));
    }
    for (kind, url) in wanted {
        let _ = save_image(app, &url, &dir.join(format!("{}.img", kind.to_ascii_lowercase()))).await;
    }
}

async fn save_image(app: &App, url: &str, path: &Path) -> Result<()> {
    let response = app.jellyfin.raw(url, &[]).await?;
    let bytes = response.bytes().await.map_err(|e| crate::jellyfin::network_error(&e))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, &bytes)?;
    Ok(())
}

/// Saved without the account's own record of it (played, play count, last
/// played, where it was left): the download folder may be readable by
/// others on the machine, and the downloads list keeps that state instead.
fn write_json(path: &Path, value: &Value) -> Result<()> {
    let mut value = value.clone();
    if let Some(item) = value.as_object_mut() {
        item.remove("UserData");
    }
    crate::paths::write_private(path, &serde_json::to_vec_pretty(&value)?)?;
    Ok(())
}

/// A metadata folder, and the `.omafin` folder holding it, open only to
/// the user: the video beside it may be shared, what the account saw of
/// it is not.
fn private_dir(meta: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(meta)?;
    let top = meta.ancestors().position(|d| d.file_name().and_then(|n| n.to_str()) == Some(".omafin"));
    for dir in meta.ancestors().take(top.map_or(1, |i| i + 1)) {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Metadata saved by earlier versions: made private, and the account's
/// viewing record taken out of it.
fn tidy_metadata(meta: &str) {
    if meta.is_empty() {
        return;
    }
    let meta = Path::new(meta);
    if !meta.is_dir() {
        return;
    }
    let _ = private_dir(meta);
    let item = meta.join("item.json");
    if let Some(value) = read_json(&item) {
        if value.get("UserData").is_some() {
            let _ = write_json(&item, &value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_safe_on_disk() {
        assert_eq!(clean_name("Mission: Impossible / Fallout"), "Mission Impossible Fallout");
        assert_eq!(clean_name("..hidden"), "hidden");
        assert_eq!(clean_name("a\nb\tc"), "a b c");
        assert_eq!(clean_name("   "), "Untitled");
        assert_eq!(clean_name("trailing. "), "trailing");
        assert!(clean_name(&"x".repeat(500)).len() <= 120);
    }

    #[test]
    fn films_and_episodes_get_their_folders() {
        let root = Path::new("/v/Omafin");
        let film = json!({ "type": "Movie", "name": "Dune: Part Two", "year": 2024 });
        let (folder, file, meta, series) = layout(root, &film, "mkv");
        assert_eq!(folder, Path::new("/v/Omafin/Movies/Dune Part Two (2024)"));
        assert_eq!(file, "Dune Part Two (2024).mkv");
        assert_eq!(meta, folder.join(".omafin"));
        assert_eq!(series, PathBuf::new());
        // A name that already ends with its year does not get it twice.
        let named = json!({ "type": "Movie", "name": "American Pie 2 (2001)", "year": 2001 });
        assert_eq!(layout(root, &named, "mov").1, "American Pie 2 (2001).mov");
        let ep = json!({ "type": "Episode", "name": "Grace", "seriesName": "Homeland", "parentIndex": 1, "index": 2 });
        let (folder, file, meta, series) = layout(root, &ep, "mp4");
        assert_eq!(folder, Path::new("/v/Omafin/Shows/Homeland/Season 01"));
        assert_eq!(file, "S01E02 - Grace.mp4");
        assert_eq!(meta, folder.join(".omafin/S01E02 - Grace"));
        assert_eq!(series, Path::new("/v/Omafin/Shows/Homeland/.omafin/series"));
    }

    #[test]
    fn extensions_come_from_the_server_name() {
        assert_eq!(extension(Some(r#"attachment; filename="Gladiator II.2024.1080p.mkv""#), "mov,mp4"), "mkv");
        assert_eq!(extension(None, "mov,mp4,m4a"), "mov");
        assert_eq!(extension(None, "../etc"), "mkv");
    }

    fn done_entry(dir: &Path, id: &str, device: u64) -> Entry {
        let folder = dir.join(format!("Film {id}"));
        Entry {
            id: format!("{id:0>32}"),
            folder: folder.to_string_lossy().into(),
            file: "film.mkv".into(),
            meta: folder.join(".omafin").to_string_lossy().into(),
            state: State::Done,
            device,
            ..Default::default()
        }
    }

    #[test]
    fn deleted_folders_are_forgotten_but_unplugged_drives_are_not() {
        use std::os::unix::fs::MetadataExt;
        let dir = tempfile::tempdir().unwrap();
        let here = std::fs::metadata(dir.path()).unwrap().dev();
        // Whole folder deleted, on a disk that is here: forgotten.
        let deleted = done_entry(dir.path(), "a", here);
        // Only the video deleted, metadata kept: stays, marked missing.
        let video_only = done_entry(dir.path(), "b", here);
        std::fs::create_dir_all(&video_only.meta).unwrap();
        // Folder gone because its drive is not there (another disk): kept.
        let unplugged = done_entry(dir.path(), "c", here + 1);
        // Still there: unchanged.
        let fine = done_entry(dir.path(), "d", here);
        std::fs::create_dir_all(&fine.meta).unwrap();
        std::fs::write(fine.video(), b"x").unwrap();
        let downloads = Downloads {
            entries: Mutex::new(vec![deleted.clone(), video_only.clone(), unplugged.clone(), fine.clone()]),
            index: dir.path().join("downloads.json"),
            wake: Notify::new(),
            watcher: Mutex::new(None),
            rewatch: Mutex::new(None),
        };
        let changes = downloads.check_files();
        assert_eq!(changes.forgotten, vec![deleted.id.clone()]);
        assert!(downloads.get(&deleted.id).is_none());
        let b = downloads.get(&video_only.id).unwrap();
        assert_eq!((b.state, b.error.as_str()), (State::Missing, "The downloaded file was removed"));
        let c = downloads.get(&unplugged.id).unwrap();
        assert_eq!((c.state, c.error.as_str()), (State::Missing, "The drive with this download is not connected"));
        assert_eq!(downloads.get(&fine.id).unwrap().state, State::Done);
        // The video comes back: done again.
        std::fs::create_dir_all(&video_only.folder).unwrap();
        std::fs::write(video_only.video(), b"x").unwrap();
        downloads.check_files();
        assert_eq!(downloads.get(&video_only.id).unwrap().state, State::Done);
    }

    #[test]
    fn metadata_is_private_and_keeps_no_viewing_record() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let dir = tempfile::tempdir().unwrap();
        let season = dir.path().join("Season 01");
        std::fs::create_dir_all(&season).unwrap();
        std::fs::set_permissions(&season, std::fs::Permissions::from_mode(0o755)).unwrap();
        let meta = season.join(".omafin/S01E01 - Pilot");
        private_dir(&meta).unwrap();
        assert_eq!((mode(&meta), mode(&season.join(".omafin")), mode(&season)), (0o700, 0o700, 0o755));
        // A sidecar from an earlier version: readable by all, with the record in it.
        let item = meta.join("item.json");
        std::fs::write(&item, br#"{"Id":"a","Name":"Pilot","UserData":{"PlayCount":3,"LastPlayedDate":"2026-01-01"}}"#).unwrap();
        std::fs::set_permissions(&item, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::set_permissions(&meta, std::fs::Permissions::from_mode(0o755)).unwrap();
        tidy_metadata(&meta.to_string_lossy());
        let saved = read_json(&item).unwrap();
        assert!(saved.get("UserData").is_none());
        assert_eq!(saved["Name"], "Pilot");
        assert_eq!((mode(&item), mode(&meta)), (0o600, 0o700));
    }

    #[test]
    fn a_download_folder_omafin_makes_is_private_and_a_chosen_one_is_left_alone() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let dir = tempfile::tempdir().unwrap();
        let made = dir.path().join("Videos/Omafin");
        make_root(&made).unwrap();
        assert_eq!(mode(&made), 0o700);
        let chosen = dir.path().join("Shared");
        std::fs::create_dir(&chosen).unwrap();
        std::fs::set_permissions(&chosen, std::fs::Permissions::from_mode(0o755)).unwrap();
        make_root(&chosen).unwrap();
        assert_eq!(mode(&chosen), 0o755);
    }

    #[test]
    fn trash_moves_and_records_where_from() {
        let dir = tempfile::tempdir().unwrap();
        unsafe { std::env::set_var("XDG_DATA_HOME", dir.path().join("data")) };
        let film = dir.path().join("Film (2020)");
        std::fs::create_dir_all(&film).unwrap();
        std::fs::write(film.join("Film (2020).mkv"), b"x").unwrap();
        let moved = move_to_trash(&film).unwrap();
        assert!(!film.exists() && moved.join("Film (2020).mkv").exists());
        let info = std::fs::read_to_string(dir.path().join("data/Trash/info/Film (2020).trashinfo")).unwrap();
        assert!(info.contains("Path=") && info.contains("Film%20%282020%29"));
    }

    #[test]
    fn finishing_a_download_never_replaces_a_file() {
        let dir = tempfile::tempdir().unwrap();
        let (part, video) = (dir.path().join("Film.mkv.part"), dir.path().join("Film.mkv"));
        std::fs::write(&part, b"download").unwrap();
        std::fs::write(&video, b"mine").unwrap();
        let err = rename_noreplace(&part, &video).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read(&video).unwrap(), b"mine");
        assert_eq!(std::fs::read(&part).unwrap(), b"download");
        std::fs::remove_file(&video).unwrap();
        rename_noreplace(&part, &video).unwrap();
        assert!(!part.exists() && std::fs::read(&video).unwrap() == b"download");
    }
}
