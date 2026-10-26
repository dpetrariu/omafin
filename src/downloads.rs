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
        let downloads = Arc::new(Self { entries: Mutex::new(entries), index, wake: Notify::new() });
        downloads.check_files();
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

    /// Finished downloads whose file was deleted (or put back) outside Omafin.
    /// Only a file that is certainly gone counts: an unreadable folder (an
    /// unmounted drive) leaves the entry as it is.
    pub fn check_files(&self) -> bool {
        let mut changed = false;
        for e in self.entries.lock().unwrap().iter_mut() {
            let gone = matches!(e.video().try_exists(), Ok(false));
            let here = matches!(e.video().try_exists(), Ok(true));
            if e.state == State::Done && gone {
                e.state = State::Missing;
                changed = true;
            } else if e.state == State::Missing && here {
                e.state = State::Done;
                changed = true;
            }
        }
        changed
    }

    pub fn list(&self) -> Vec<Value> {
        self.entries.lock().unwrap().iter().map(Entry::to_json).collect()
    }
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
        let title = match card["year"].as_i64() {
            Some(year) => clean_name(&format!("{name} ({year})")),
            None => clean_name(name),
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

// ---------------------------------------------------------------- RPC

pub async fn list(app: &App) -> Result<Value> {
    if app.downloads.check_files() {
        app.downloads.save();
    }
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
    // only need their own file name.
    {
        let entries = app.downloads.entries.lock().unwrap();
        let tag = &id[..8];
        if card["type"] == "Episode" {
            if entries.iter().any(|e| e.id != id && e.folder == folder.to_string_lossy() && e.file == file) {
                let stem = file.trim_end_matches(&format!(".{ext}")).to_string();
                meta = meta.with_file_name(format!("{stem} [{tag}]"));
                file = format!("{stem} [{tag}].{ext}");
            }
        } else if entries.iter().any(|e| e.id != id && e.folder == folder.to_string_lossy()) {
            let name = format!("{} [{tag}]", folder.file_name().and_then(|n| n.to_str()).unwrap_or("Untitled"));
            folder = folder.with_file_name(&name);
            meta = folder.join(".omafin");
            file = format!("{name}.{ext}");
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
    if entry.card["type"] == "Episode" {
        // Episodes share their season folder: the video, then its own metadata.
        for path in [entry.video(), PathBuf::from(&entry.meta)] {
            if matches!(path.try_exists(), Ok(true)) {
                trashed.push(move_to_trash(&path).map_err(|e| Error::internal(format!("Could not move to the trash: {e}")))?);
            }
        }
    } else if matches!(root.try_exists(), Ok(true)) {
        // A film's folder holds only that film and its metadata.
        trashed.push(move_to_trash(&root).map_err(|e| Error::internal(format!("Could not move to the trash: {e}")))?);
    }
    app.downloads.entries.lock().unwrap().retain(|e| e.id != id);
    app.downloads.save();
    tidy(app, &entry);
    notify_removed(app, id);
    Ok(json!({ "trashed": trashed }))
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
    std::fs::create_dir_all(&files)?;
    std::fs::create_dir_all(&info)?;
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
    std::fs::write(&info_file, format!("[Trash Info]\nPath={encoded}\nDeletionDate={stamp}\n"))?;
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
pub fn start(app: Arc<App>) {
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
}

/// Still wanted? A pause, cancel or removal changes the entry's state.
fn wanted(app: &App, id: &str) -> bool {
    app.downloads.get(id).map(|e| e.state == State::Downloading).unwrap_or(false)
}

async fn transfer(app: &Arc<App>, entry: &Entry) -> Outcome {
    let folder = PathBuf::from(&entry.folder);
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
    let file = std::fs::OpenOptions::new().create(true).write(true).truncate(have == 0).open(&part);
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
    if let Err(err) = std::fs::rename(&part, entry.video()) {
        return Outcome::Fail(format!("Could not finish the file: {err}"));
    }
    Outcome::Done
}

/// The item, its pictures, its text subtitles and (for an episode) its
/// show, saved beside the video for the Downloaded view and offline use.
async fn save_metadata(app: &App, entry: &Entry) -> Result<()> {
    let uid = user_id(app)?;
    let meta = PathBuf::from(&entry.meta);
    std::fs::create_dir_all(&meta)?;
    let item = app.jellyfin.get(&format!("/Items/{}?userId={uid}", entry.id)).await?;
    write_json(&meta.join("item.json"), &item)?;
    save_images(app, &item, &meta).await;
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
                std::fs::create_dir_all(&series_meta)?;
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

fn write_json(path: &Path, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, &bytes)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
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
}
