//! Playing something: asking Jellyfin how (PlaybackInfo), building the stream
//! the player loads through the media proxy, and telling Jellyfin where you
//! are, so Continue watching and watched marks follow you to other devices.
//!
//! One session at a time. The window reports its own position through
//! `play.report`; when mpv plays, this module drives it over mpv's JSON IPC
//! socket and reports for it.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;

use crate::app::App;
use crate::error::{Error, Result};
use crate::jellyfin::profile::{self, Player};
use crate::jellyfin::{TICKS_PER_SECOND, require_id};
use crate::library::{self, str_param, user_id};
use std::path::Path;

const REPORT_EVERY: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
pub struct Session {
    pub id: String,
    pub item_id: String,
    pub source_id: String,
    pub method: &'static str,
    pub audio: Option<i64>,
    pub subtitle: Option<i64>,
    pub position: f64,
    pub paused: bool,
    pub started: bool,
    pub player: Player,
    /// Playing a downloaded file: positions are kept with the download too,
    /// and remembered for the server when it cannot be told.
    pub local: bool,
    pub runtime: f64,
    last_report: Option<Instant>,
}

#[derive(Default)]
pub struct Playback {
    current: Mutex<Option<Session>>,
    /// The mpv this module started: the session it plays and a way to end
    /// it. The process itself belongs to the task that drives it.
    mpv: std::sync::Mutex<Option<(String, tokio::sync::oneshot::Sender<()>)>>,
    /// Reports go out one at a time, so a Progress never lands after its Stopped.
    reporting: Mutex<()>,
}

impl Playback {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
}

fn ticks(seconds: f64) -> i64 {
    (seconds.max(0.0) * TICKS_PER_SECOND as f64) as i64
}

fn int_param(params: &Value, name: &str) -> Option<i64> {
    params.get(name).and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

/// Which bitrate to ask for: what the call says, or the setting for the
/// address in use (home or away).
async fn bitrate(app: &App, params: &Value) -> u64 {
    if let Some(b) = params.get("maxBitrate").and_then(|v| v.as_u64()) {
        return b.min(400_000_000);
    }
    let settings = app.settings();
    let away = app.jellyfin.route().await.map(|r| r.route == "wan").unwrap_or(false);
    if away { settings.playback.max_bitrate_away } else { settings.playback.max_bitrate }
}

/// Remove the access token Jellyfin writes into its own URLs; the proxy adds
/// it as a header instead, so it never reaches the player or QML.
pub fn strip_token(url: &str) -> String {
    let (path, query) = url.split_once('?').unwrap_or((url, ""));
    let kept: Vec<&str> = query
        .split('&')
        .filter(|kv| !kv.is_empty())
        .filter(|kv| {
            let key = kv.split('=').next().unwrap_or("").to_ascii_lowercase();
            key != "apikey" && key != "api_key"
        })
        .collect();
    if kept.is_empty() { path.to_string() } else { format!("{path}?{}", kept.join("&")) }
}

fn has_param(url: &str, name: &str) -> bool {
    url.split_once('?')
        .map(|(_, q)| q.split('&').any(|kv| kv.split('=').next().unwrap_or("").eq_ignore_ascii_case(name)))
        .unwrap_or(false)
}

/// The proxy path (relative to the media base) for a Jellyfin path.
fn proxied(path: &str) -> String {
    format!("/jf{}", strip_token(path))
}

fn subtitle_path(item: &str, source: &str, stream: &Value, format: &str) -> Value {
    let Some(index) = stream["index"].as_i64() else { return Value::Null };
    json!(proxied(&format!("/Videos/{item}/{source}/Subtitles/{index}/0/Stream.{format}")))
}

/// The ordinal (1-based) of a Jellyfin stream among the file's own streams
/// of that type, which is how mpv and Qt number tracks.
pub fn track_ordinal(streams: &[Value], kind: &str, index: i64) -> Option<usize> {
    let embedded: Vec<i64> = streams
        .iter()
        .filter(|s| s["type"] == kind && s["isExternal"] != true)
        .filter_map(|s| s["index"].as_i64())
        .collect();
    embedded.iter().position(|i| *i == index).map(|p| p + 1)
}

/// Ask Jellyfin how to play an item and prepare everything a player needs.
pub async fn prepare(app: &App, params: &Value, player: Player) -> Result<Value> {
    let id = require_id(str_param(params, "id"))?.to_string();
    // A downloaded title plays from its file, without asking the server.
    if let Some(entry) = app.downloads.playable(&id) {
        return prepare_local(app, params, player, entry).await;
    }
    let uid = user_id(app)?;
    let item = app.jellyfin.get(&format!("/Items/{id}?userId={uid}")).await?;
    if item.get("MediaType").and_then(|v| v.as_str()) != Some("Video") {
        return Err(Error::invalid("Omafin plays films and episodes"));
    }
    let requested_source = match str_param(params, "mediaSourceId") {
        "" => None,
        s => Some(require_id(s)?.to_string()),
    };
    let source_info = item
        .get("MediaSources")
        .and_then(|v| v.as_array())
        .and_then(|a| {
            a.iter()
                .find(|ms| requested_source.as_deref().map(|r| ms["Id"].as_str() == Some(r)).unwrap_or(true))
                .cloned()
        })
        .ok_or_else(|| Error::invalid("That video has no playable file"))?;
    let source = library::media_source(&source_info);
    let source_id = source["id"].as_str().unwrap_or(&id).to_string();
    require_id(&source_id).map_err(|_| Error::new(crate::error::SERVER, "Jellyfin named the file oddly; Omafin will not play it"))?;
    let streams: Vec<Value> = source["streams"].as_array().cloned().unwrap_or_default();

    let settings = app.settings();
    let audio = int_param(params, "audioIndex")
        .or_else(|| pick_audio(&streams, &settings.playback.audio_language))
        .or_else(|| source["defaultAudio"].as_i64());
    let subtitle = match int_param(params, "subtitleIndex") {
        Some(i) if i < 0 => None,
        Some(i) => Some(i),
        None => pick_subtitle(&streams, &settings.playback, audio, source["defaultSubtitle"].as_i64()),
    };
    // Converting is the server's work; unless it is allowed, the original
    // file always plays and nothing asks the server to transcode.
    let allow = settings.playback.allow_transcoding;
    let chosen_sub = subtitle.and_then(|i| streams.iter().find(|s| s["type"] == "Subtitle" && s["index"].as_i64() == Some(i)).cloned());
    let picture_sub = player == Player::Window
        && chosen_sub.as_ref().map(|s| profile::is_picture_subtitle(s["codec"].as_str().unwrap_or(""))).unwrap_or(false);
    // The window cannot draw picture subtitles: the server burns them in
    // when it may; otherwise they are left off here (mpv shows them).
    let (subtitle, needs_mpv) = if picture_sub && !allow { (None, subtitle) } else { (subtitle, None) };
    let burn_in = picture_sub && allow;
    let start = params.get("start").and_then(|v| v.as_f64()).unwrap_or(0.0).max(0.0);
    // After a file the window could not decode, the server converts it.
    let force_transcode = params.get("transcode").and_then(|v| v.as_bool()).unwrap_or(false);
    if force_transcode && !allow {
        return Err(Error::invalid("The server is set not to convert videos; play this one in mpv instead"));
    }
    let convert = burn_in || force_transcode;
    let max_bitrate = if allow { bitrate(app, params).await } else { 0 };

    let mut query = vec![
        format!("userId={uid}"),
        format!("mediaSourceId={source_id}"),
        format!("startTimeTicks={}", ticks(start)),
        "autoOpenLiveStream=true".to_string(),
    ];
    if let Some(a) = audio {
        query.push(format!("audioStreamIndex={a}"));
    }
    query.push(format!("subtitleStreamIndex={}", subtitle.unwrap_or(-1)));
    if max_bitrate > 0 {
        query.push(format!("maxStreamingBitrate={max_bitrate}"));
    }
    if !allow {
        query.push("enableTranscoding=false&enableDirectStream=false".into());
    }
    let body = json!({
        "UserId": uid,
        "MediaSourceId": source_id,
        "StartTimeTicks": ticks(start),
        "AudioStreamIndex": audio,
        "SubtitleStreamIndex": subtitle.unwrap_or(-1),
        "MaxStreamingBitrate": if max_bitrate > 0 { json!(max_bitrate) } else { Value::Null },
        "DeviceProfile": profile::device_profile(player, max_bitrate, allow),
        "EnableDirectPlay": !convert,
        "EnableDirectStream": !convert && allow,
        "EnableTranscoding": allow,
        "AllowVideoStreamCopy": !convert,
        "AllowAudioStreamCopy": allow,
        "AutoOpenLiveStream": true,
    });
    let info = app.jellyfin.post(&format!("/Items/{id}/PlaybackInfo?{}", query.join("&")), body).await?;
    if let Some(code) = info.get("ErrorCode").and_then(|v| v.as_str()) {
        return Err(Error::new(crate::error::SERVER, match code {
            "NotAllowed" => "Your Jellyfin account may not play this".to_string(),
            "NoCompatibleStream" => "Jellyfin found no way to send this video to Omafin".to_string(),
            "RateLimitExceeded" => "Jellyfin is busy with too many streams; try again soon".to_string(),
            other => format!("Jellyfin could not play this ({other})"),
        }));
    }
    let session_id = info.get("PlaySessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if session_id.len() > 64 || !session_id.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err(Error::new(crate::error::SERVER, "Jellyfin sent an odd play session"));
    }
    let answered = info
        .get("MediaSources")
        .and_then(|v| v.as_array())
        .and_then(|a| a.iter().find(|ms| ms["Id"].as_str() == Some(&source_id)).or_else(|| a.first()))
        .cloned()
        .ok_or_else(|| Error::new(crate::error::SERVER, "Jellyfin offered no way to play this"))?;
    // Without conversion, the file plays as it is even when the server would
    // rather convert it: both players decode nearly everything.
    let direct = (answered["SupportsDirectPlay"].as_bool().unwrap_or(false) || !allow) && !convert;
    let (method, path, reasons) = if direct {
        let mut url = format!("/Videos/{id}/stream?static=true&mediaSourceId={source_id}&deviceId={}", app.jellyfin.device_id());
        if !session_id.is_empty() {
            url.push_str(&format!("&playSessionId={session_id}"));
        }
        if let Some(tag) = answered["ETag"].as_str().filter(|t| t.chars().all(|c| c.is_ascii_alphanumeric())) {
            url.push_str(&format!("&tag={tag}"));
        }
        ("DirectPlay", url, Vec::new())
    } else if let Some(url) = answered["TranscodingUrl"].as_str() {
        let mut url = url.to_string();
        if !url.starts_with('/') {
            return Err(Error::new(crate::error::SERVER, "Jellyfin offered a stream on another server"));
        }
        if let Some(sub) = subtitle.filter(|_| burn_in) {
            if !has_param(&url, "SubtitleStreamIndex") {
                url.push_str(&format!("&SubtitleStreamIndex={sub}"));
            }
        }
        let reasons: Vec<String> = url
            .split_once('?')
            .and_then(|(_, q)| q.split('&').find_map(|kv| kv.strip_prefix("TranscodeReasons=")))
            .map(|r| r.split(',').map(String::from).collect())
            .unwrap_or_default();
        let method = if answered["SupportsDirectStream"].as_bool() == Some(true) && !convert { "DirectStream" } else { "Transcode" };
        (method, url, reasons)
    } else {
        return Err(Error::new(crate::error::SERVER, "Jellyfin found no way to send this video to Omafin"));
    };
    let segments = media_segments(app, &id).await.unwrap_or_default();
    let subtitles: Vec<Value> = streams
        .iter()
        .filter(|s| s["type"] == "Subtitle")
        .map(|s| {
            let picture = profile::is_picture_subtitle(s["codec"].as_str().unwrap_or(""));
            let mut s = s.clone();
            s["picture"] = json!(picture);
            s["url"] = if picture { Value::Null } else { subtitle_path(&id, &source_id, &s, "vtt") };
            s
        })
        .collect();
    let audio_tracks: Vec<Value> = streams.iter().filter(|s| s["type"] == "Audio").cloned().collect();
    let video = streams.iter().find(|s| s["type"] == "Video").cloned().unwrap_or(Value::Null);
    let card = library::card(&item);

    let session = Session {
        id: session_id.clone(),
        item_id: id.clone(),
        source_id: source_id.clone(),
        method,
        audio,
        subtitle,
        position: start,
        paused: false,
        started: false,
        player,
        local: false,
        runtime: source["runtime"].as_f64().unwrap_or(0.0),
        last_report: None,
    };
    // A new session ends the old one, so the server stops any transcode,
    // and a window play ends an mpv one.
    let previous = app.playback.current.lock().await.replace(session);
    if let Some(previous) = previous {
        end_session(app, &previous).await;
    }
    if player == Player::Window {
        stop_mpv(app);
    }

    Ok(json!({
        "session": session_id,
        "item": card,
        "sourceId": source_id,
        "method": method,
        "transcodeReasons": reasons,
        "url": proxied(&path),
        "hls": !direct,
        // Jellyfin's HLS playlists cover the whole video, so every player
        // seeks to `start` itself.
        "start": start,
        "runtime": source["runtime"].as_f64().or(card["runtime"].as_f64()),
        "audioIndex": audio,
        "subtitleIndex": subtitle,
        "burnedIn": burn_in,
        "allowTranscoding": allow,
        // Picture subtitles asked for that only mpv can show without the server.
        "needsMpv": needs_mpv,
        "audio": audio_tracks,
        "subtitles": subtitles,
        "video": video,
        "audioTrack": audio.and_then(|a| track_ordinal(&streams, "Audio", a)),
        "segments": segments,
        "chapters": item.get("Chapters").and_then(|v| v.as_array()).map(|a| a.iter().map(|c| json!({
            "name": c.get("Name").cloned().unwrap_or(Value::Null),
            "start": c.get("StartPositionTicks").and_then(|v| v.as_i64()).map(|t| t as f64 / TICKS_PER_SECOND as f64).unwrap_or(0.0),
        })).collect::<Vec<_>>()).unwrap_or_default(),
        "trickplay": library::trickplay(&item, &source_id),
    }))
}

fn pick_audio(streams: &[Value], language: &str) -> Option<i64> {
    if language.is_empty() {
        return None;
    }
    streams
        .iter()
        .filter(|s| s["type"] == "Audio" && s["language"].as_str() == Some(language))
        .max_by_key(|s| s["isDefault"] == true)
        .and_then(|s| s["index"].as_i64())
}

fn pick_subtitle(streams: &[Value], prefs: &crate::config::PlaybackSettings, audio: Option<i64>, default: Option<i64>) -> Option<i64> {
    let subs: Vec<&Value> = streams.iter().filter(|s| s["type"] == "Subtitle").collect();
    let in_language = |forced_only: bool| -> Option<i64> {
        subs.iter()
            .filter(|s| prefs.subtitle_language.is_empty() || s["language"].as_str() == Some(prefs.subtitle_language.as_str()))
            .filter(|s| !forced_only || s["isForced"] == true)
            .max_by_key(|s| (s["isText"] == true, s["isDefault"] == true))
            .and_then(|s| s["index"].as_i64())
    };
    match prefs.subtitle_mode.as_str() {
        "none" => None,
        "always" => in_language(false).or(default.filter(|d| *d >= 0)),
        "foreign" => {
            let audio_lang = audio
                .and_then(|a| streams.iter().find(|s| s["index"].as_i64() == Some(a)))
                .and_then(|s| s["language"].as_str())
                .unwrap_or("");
            let own = prefs.audio_language.as_str();
            if !own.is_empty() && audio_lang != own { in_language(false) } else { in_language(true) }
        }
        _ => default.filter(|d| *d >= 0),
    }
}

/// Intros, recaps, credits and previews, in seconds.
async fn media_segments(app: &App, id: &str) -> Result<Vec<Value>> {
    let list = app.jellyfin.get(&format!("/MediaSegments/{id}")).await?;
    Ok(segments_of(&list))
}

fn report_body(session: &Session) -> Value {
    json!({
        "ItemId": session.item_id,
        "MediaSourceId": session.source_id,
        "PlaySessionId": session.id,
        "PositionTicks": ticks(session.position),
        "IsPaused": session.paused,
        "IsMuted": false,
        "CanSeek": true,
        "PlayMethod": session.method,
        "AudioStreamIndex": session.audio,
        "SubtitleStreamIndex": session.subtitle.unwrap_or(-1),
        "RepeatMode": "RepeatNone",
    })
}

/// Play a downloaded file: everything comes from what the download saved,
/// so it works with the server out of reach.
async fn prepare_local(app: &App, params: &Value, player: Player, entry: crate::downloads::Entry) -> Result<Value> {
    let id = entry.id.clone();
    let item = crate::downloads::Downloads::item_json(&entry)
        .ok_or_else(|| Error::internal("The download's details are missing; download it again"))?;
    let source_info = item
        .get("MediaSources")
        .and_then(|v| v.as_array())
        .and_then(|a| a.iter().find(|s| s["Id"].as_str() == Some(&entry.source_id)).or_else(|| a.first()))
        .cloned()
        .unwrap_or(Value::Null);
    let source = library::media_source(&source_info);
    let source_id = entry.source_id.clone();
    let streams: Vec<Value> = source["streams"].as_array().cloned().unwrap_or_default();
    let settings = app.settings();
    let audio = int_param(params, "audioIndex")
        .or_else(|| pick_audio(&streams, &settings.playback.audio_language))
        .or_else(|| source["defaultAudio"].as_i64());
    let mut subtitle = match int_param(params, "subtitleIndex") {
        Some(i) if i < 0 => None,
        Some(i) => Some(i),
        None => pick_subtitle(&streams, &settings.playback, audio, source["defaultSubtitle"].as_i64()),
    };
    let mut needs_mpv = Value::Null;
    if player == Player::Window {
        let chosen = subtitle.and_then(|i| streams.iter().find(|s| s["type"] == "Subtitle" && s["index"].as_i64() == Some(i)));
        if chosen.map(|s| profile::is_picture_subtitle(s["codec"].as_str().unwrap_or(""))).unwrap_or(false) {
            // Nothing converts offline: picture subtitles are mpv's.
            needs_mpv = json!(subtitle);
            subtitle = None;
        }
    }
    let start = params.get("start").and_then(|v| v.as_f64()).unwrap_or(0.0).max(0.0);
    let subtitles: Vec<Value> = streams
        .iter()
        .filter(|s| s["type"] == "Subtitle")
        .map(|s| {
            let picture = profile::is_picture_subtitle(s["codec"].as_str().unwrap_or(""));
            let index = s["index"].as_i64().unwrap_or(-1);
            let mut s = s.clone();
            s["picture"] = json!(picture);
            s["url"] = if !picture && app.downloads.subtitle_file(&id, index).is_some() { json!(format!("/local/{id}/sub/{index}")) } else { Value::Null };
            s
        })
        .collect();
    let segments: Vec<Value> = std::fs::read(Path::new(&entry.meta).join("segments.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .map(|v| segments_of(&v))
        .unwrap_or_default();
    let mut card = entry.card.clone();
    card["offline"] = json!(true);
    let runtime = source["runtime"].as_f64().or(card["runtime"].as_f64()).unwrap_or(0.0);
    let session_id = format!("L{}", crate::config::new_id());
    let session = Session {
        id: session_id.clone(),
        item_id: id.clone(),
        source_id: source_id.clone(),
        method: "DirectPlay",
        audio,
        subtitle,
        position: start,
        paused: false,
        started: false,
        player,
        local: true,
        runtime,
        last_report: None,
    };
    let previous = app.playback.current.lock().await.replace(session);
    if let Some(previous) = previous {
        end_session(app, &previous).await;
    }
    if player == Player::Window {
        stop_mpv(app);
    }
    Ok(json!({
        "session": session_id,
        "item": card,
        "sourceId": source_id,
        "method": "DirectPlay",
        "transcodeReasons": [],
        "url": format!("/local/{id}/file"),
        "local": true,
        "hls": false,
        "start": start,
        "runtime": runtime,
        "audioIndex": audio,
        "subtitleIndex": subtitle,
        "burnedIn": false,
        "allowTranscoding": false,
        "needsMpv": needs_mpv,
        "audio": streams.iter().filter(|s| s["type"] == "Audio").cloned().collect::<Vec<_>>(),
        "subtitles": subtitles,
        "video": streams.iter().find(|s| s["type"] == "Video").cloned().unwrap_or(Value::Null),
        "audioTrack": audio.and_then(|a| track_ordinal(&streams, "Audio", a)),
        "segments": segments,
        "chapters": item.get("Chapters").and_then(|v| v.as_array()).map(|a| a.iter().map(|c| json!({
            "name": c.get("Name").cloned().unwrap_or(Value::Null),
            "start": c.get("StartPositionTicks").and_then(|v| v.as_i64()).map(|t| t as f64 / TICKS_PER_SECOND as f64).unwrap_or(0.0),
        })).collect::<Vec<_>>()).unwrap_or_default(),
        "trickplay": Value::Null,
    }))
}

fn segments_of(list: &Value) -> Vec<Value> {
    list.get("Items")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|s| {
                    let kind = s.get("Type")?.as_str()?;
                    let start = s.get("StartTicks")?.as_i64()? as f64 / TICKS_PER_SECOND as f64;
                    let end = s.get("EndTicks")?.as_i64()? as f64 / TICKS_PER_SECOND as f64;
                    (end > start).then(|| json!({ "type": kind, "start": start, "end": end }))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// A downloaded title's place, kept with the download (and for the server
/// when it could not be told).
fn record_local(app: &App, session: &Session, told: bool) {
    if session.local {
        if let Some(entry) = app.downloads.record_progress(&session.item_id, session.position, session.runtime, told) {
            crate::downloads::notify_entry(app, &entry);
        }
    }
}

async fn report_stopped(app: &App, session: &Session) -> Result<Value> {
    let _order = app.playback.reporting.lock().await;
    app.jellyfin.post("/Sessions/Playing/Stopped", report_body(session)).await
}

/// Tell the server a session is over: one that played, and one that never
/// started but may have set a transcode going.
async fn end_session(app: &App, session: &Session) {
    if session.started || session.method != "DirectPlay" {
        let told = report_stopped(app, session).await.is_ok();
        if session.started {
            record_local(app, session, told);
        }
    }
}

fn stop_mpv(app: &App) {
    if let Some((_, stop)) = app.playback.mpv.lock().unwrap().take() {
        let _ = stop.send(());
    }
}

/// Where the window's player is. `event` is start, progress, pause, resume,
/// seek or stop; progress is sent on at most every ten seconds.
pub async fn report(app: &App, params: &Value) -> Result<Value> {
    let session_id = str_param(params, "session");
    let event = str_param(params, "event");
    let position = params.get("position").and_then(|v| v.as_f64()).unwrap_or(0.0).max(0.0);
    let _order = app.playback.reporting.lock().await;
    let snapshot = {
        let mut guard = app.playback.current.lock().await;
        let Some(session) = guard.as_mut().filter(|s| s.id == session_id && s.player == Player::Window) else {
            return Ok(json!({ "reported": false }));
        };
        session.position = position;
        if let Some(a) = int_param(params, "audioIndex") {
            session.audio = Some(a);
        }
        if let Some(s) = int_param(params, "subtitleIndex") {
            session.subtitle = (s >= 0).then_some(s);
        }
        match event {
            "start" => session.started = true,
            "pause" => session.paused = true,
            "resume" => session.paused = false,
            "progress" | "seek" | "stop" => {}
            _ => return Err(Error::invalid("Unknown playback event")),
        }
        let due = session.last_report.map(|t| t.elapsed() >= REPORT_EVERY).unwrap_or(true);
        if event == "progress" && !due {
            return Ok(json!({ "reported": false }));
        }
        if event == "stop" && !session.started {
            // Never played, but a transcode may be running: end it.
            let snapshot = session.clone();
            *guard = None;
            drop(guard);
            if snapshot.method != "DirectPlay" {
                app.jellyfin.post("/Sessions/Playing/Stopped", report_body(&snapshot)).await?;
                return Ok(json!({ "reported": true }));
            }
            return Ok(json!({ "reported": false }));
        }
        if event != "start" && !session.started {
            return Ok(json!({ "reported": false }));
        }
        session.last_report = Some(Instant::now());
        let snapshot = session.clone();
        if event == "stop" {
            *guard = None;
        }
        snapshot
    };
    let mut body = report_body(&snapshot);
    let path = match event {
        "start" => "/Sessions/Playing",
        "stop" => "/Sessions/Playing/Stopped",
        _ => {
            body["EventName"] = json!(match event {
                "pause" => "Pause",
                "resume" => "Unpause",
                _ => "TimeUpdate",
            });
            "/Sessions/Playing/Progress"
        }
    };
    let sent = app.jellyfin.post(path, body).await;
    if snapshot.local {
        // A download's place is kept whether or not the server heard.
        record_local(app, &snapshot, sent.is_ok());
        return Ok(json!({ "reported": sent.is_ok(), "kept": true }));
    }
    sent?;
    Ok(json!({ "reported": true }))
}

// ---------------------------------------------------------------- mpv

pub fn mpv_available() -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|p| p.join("mpv").is_file()))
        .unwrap_or(false)
}

/// Hand an item to mpv. mpv loads it through the media proxy, so the token
/// is not in its command line; this module reports progress for it.
pub async fn play_in_mpv(app: &Arc<App>, params: &Value) -> Result<Value> {
    if !mpv_available() {
        return Err(Error::invalid("mpv is not installed (sudo pacman -S mpv)"));
    }
    let mut prepared = prepare(app, params, Player::Mpv).await?;
    // Replace an mpv that is still playing something else; its own task
    // reports and cleans up after it.
    stop_mpv(app);
    let base = app.media.base_url();
    let url = format!("{base}{}", prepared["url"].as_str().unwrap_or_default());
    let streams: Vec<Value> = prepared["audio"].as_array().cloned().unwrap_or_default()
        .into_iter()
        .chain(prepared["subtitles"].as_array().cloned().unwrap_or_default())
        .collect();
    let mut options = vec![format!("start={}", prepared["start"].as_f64().unwrap_or(0.0))];
    if let Some(a) = prepared["audioIndex"].as_i64().and_then(|a| track_ordinal(&streams, "Audio", a)) {
        options.push(format!("aid={a}"));
    }
    let external_sub = prepared["subtitleIndex"].as_i64().and_then(|i| {
        prepared["subtitles"].as_array()?.iter().find(|s| s["index"].as_i64() == Some(i) && s["isExternal"] == true).cloned()
    });
    match prepared["subtitleIndex"].as_i64() {
        None => options.push("sid=no".into()),
        Some(i) => {
            if let Some(ordinal) = track_ordinal(&streams, "Subtitle", i).filter(|_| external_sub.is_none()) {
                options.push(format!("sid={ordinal}"));
            }
        }
    }
    // mpv numbers tracks in file order; reports need Jellyfin's numbers.
    let embedded = |kind: &str| -> Vec<i64> {
        streams.iter().filter(|s| s["type"] == kind && s["isExternal"] != true).filter_map(|s| s["index"].as_i64()).collect()
    };
    let audio_map = embedded("Audio");
    let mut subtitle_map = embedded("Subtitle");
    let title = mpv_title(&prepared["item"]);
    let session = prepared["session"].as_str().unwrap_or_default().to_string();
    let socket = mpv_socket(app, &session)?;
    let _ = std::fs::remove_file(&socket);
    let child = tokio::process::Command::new("mpv")
        .arg("--idle=once")
        .arg("--force-window=immediate")
        .arg("--keep-open=no")
        .arg(format!("--input-ipc-server={}", socket.display()))
        .arg(format!("--force-media-title={title}"))
        .arg("--msg-level=all=warn")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| Error::internal(format!("Could not start mpv: {e}")))?;
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel();
    *app.playback.mpv.lock().unwrap() = Some((session.clone(), stop_tx));
    let sub_url = external_sub.and_then(|s| {
        let index = s["index"].as_i64()?;
        let item = prepared["item"]["id"].as_str()?.to_string();
        let source = prepared["sourceId"].as_str()?.to_string();
        let format = match s["codec"].as_str() {
            Some("ass") => "ass",
            Some("ssa") => "ssa",
            _ => "srt",
        };
        subtitle_map.push(index);
        if prepared["local"] == true {
            return Some(format!("{base}/local/{item}/sub/{index}"));
        }
        Some(format!("{base}/jf/Videos/{item}/{source}/Subtitles/{index}/0/Stream.{format}"))
    });
    let app = app.clone();
    let tracks = Tracks { audio: audio_map, subtitle: subtitle_map };
    let job = MpvJob { socket, url, options: options.join(","), sub_url, session, tracks };
    tokio::spawn(async move {
        drive_mpv(app, child, job, stop_rx).await;
    });
    prepared["url"] = Value::Null;
    Ok(prepared)
}

fn mpv_title(item: &Value) -> String {
    let name = item["name"].as_str().unwrap_or("Omafin");
    let title = match (item["seriesName"].as_str(), item["parentIndex"].as_i64(), item["index"].as_i64()) {
        (Some(series), Some(s), Some(e)) => format!("{series} S{s:02}E{e:02} · {name}"),
        (Some(series), _, _) => format!("{series} · {name}"),
        _ => name.to_string(),
    };
    title.chars().filter(|c| !c.is_control()).take(200).collect()
}

/// One socket per play, so an mpv that is closing never takes the next
/// one's. Short, since a Unix socket path holds at most 107 bytes.
fn mpv_socket(app: &App, session: &str) -> Result<PathBuf> {
    let dir = app.paths.runtime_dir();
    std::fs::create_dir_all(&dir)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    let name: String = session.chars().take(12).collect();
    Ok(dir.join(format!("mpv-{name}.sock")))
}

/// An mpv option value in a `loadfile` options list: commas and quotes are
/// not allowed through, which none of ours need.
fn option_safe(value: &str) -> bool {
    !value.contains(',') && !value.contains('"') && !value.contains('\n')
}

/// Jellyfin's stream numbers for mpv's track numbers (1-based).
struct Tracks {
    audio: Vec<i64>,
    subtitle: Vec<i64>,
}

impl Tracks {
    fn jellyfin(list: &[i64], mpv: &Value) -> Option<i64> {
        let n = mpv.as_u64()? as usize;
        n.checked_sub(1).and_then(|i| list.get(i)).copied()
    }
}

struct MpvJob {
    socket: PathBuf,
    url: String,
    options: String,
    sub_url: Option<String>,
    session: String,
    tracks: Tracks,
}

/// Run one mpv to its end, reporting for it. Whatever ends it (the person
/// closing mpv, the end of the file, a new play, sign-out), this task stops
/// the process, removes its socket and tells the server and the window.
async fn drive_mpv(app: Arc<App>, mut child: tokio::process::Child, job: MpvJob, stop: tokio::sync::oneshot::Receiver<()>) {
    let ended_at_end = match talk_to_mpv(&app, &mut child, &job, stop).await {
        Ok(ended) => ended,
        Err(err) => {
            eprintln!("omafin: mpv: {err}");
            false
        }
    };
    let _ = child.start_kill();
    let _ = child.wait().await;
    let _ = std::fs::remove_file(&job.socket);
    {
        let mut slot = app.playback.mpv.lock().unwrap();
        if slot.as_ref().map(|(s, _)| s == &job.session).unwrap_or(false) {
            *slot = None;
        }
    }
    let finished = {
        let mut guard = app.playback.current.lock().await;
        if guard.as_ref().map(|s| s.id == job.session).unwrap_or(false) { guard.take() } else { None }
    };
    let mut position = None;
    let mut item = Value::Null;
    if let Some(s) = finished {
        position = Some(s.position);
        item = json!(s.item_id);
        end_session(&app, &s).await;
    }
    // Always said, so the bar never keeps showing "Playing in mpv".
    app.notifier.notify(
        "playback.changed",
        json!({ "itemId": item, "state": "stopped", "player": "mpv", "position": position, "ended": ended_at_end }),
    );
}

/// The conversation with mpv. Returns whether the file played to its end.
async fn talk_to_mpv(app: &Arc<App>, child: &mut tokio::process::Child, job: &MpvJob, mut stop: tokio::sync::oneshot::Receiver<()>) -> Result<bool> {
    let mut stream = None;
    for _ in 0..100 {
        if let Ok(s) = tokio::net::UnixStream::connect(&job.socket).await {
            stream = Some(s);
            break;
        }
        if let Ok(Some(_)) = child.try_wait() {
            return Err(Error::internal("mpv quit before it opened its control socket"));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let stream = stream.ok_or_else(|| Error::internal("mpv did not open its control socket"))?;
    let (read, mut write) = stream.into_split();
    for c in [
        json!({ "command": ["observe_property", 1, "time-pos"] }),
        json!({ "command": ["observe_property", 2, "pause"] }),
        json!({ "command": ["observe_property", 3, "aid"] }),
        json!({ "command": ["observe_property", 4, "sid"] }),
        json!({ "command": ["loadfile", job.url, "replace", -1, job.options] }),
    ] {
        write.write_all(format!("{c}\n").as_bytes()).await?;
    }
    let mut pending_sub = job.sub_url.clone().filter(|s| option_safe(s));
    let mut lines = BufReader::new(read).lines();
    let mut ended_at_end = false;
    loop {
        let line = tokio::select! {
            line = lines.next_line() => match line {
                Ok(Some(line)) => line,
                _ => break,
            },
            _ = &mut stop => break,
        };
        let Ok(event) = serde_json::from_str::<Value>(&line) else { continue };
        match event["event"].as_str() {
            Some("file-loaded") => {
                // After the file has loaded, so the track joins it.
                if let Some(sub) = pending_sub.take() {
                    let c = json!({ "command": ["sub-add", sub, "select"], "async": true, "request_id": 9 });
                    write.write_all(format!("{c}\n").as_bytes()).await?;
                }
            }
            Some("playback-restart") => {
                let start = {
                    let mut guard = app.playback.current.lock().await;
                    match guard.as_mut() {
                        Some(s) if s.id == job.session && !s.started => {
                            s.started = true;
                            s.last_report = Some(Instant::now());
                            Some(s.clone())
                        }
                        Some(s) if s.id == job.session => None,
                        // Something else plays now; this mpv is done.
                        _ => break,
                    }
                };
                if let Some(s) = start {
                    let _order = app.playback.reporting.lock().await;
                    let _ = app.jellyfin.post("/Sessions/Playing", report_body(&s)).await;
                    app.notifier.notify("playback.changed", json!({ "itemId": s.item_id, "state": "playing", "player": "mpv" }));
                }
            }
            Some("end-file") => {
                ended_at_end = event["reason"] == "eof";
            }
            Some("property-change") => {
                let due = {
                    let mut guard = app.playback.current.lock().await;
                    let Some(s) = guard.as_mut().filter(|s| s.id == job.session) else { break };
                    let mut event_name = "TimeUpdate";
                    match event["name"].as_str() {
                        Some("time-pos") => {
                            if let Some(t) = event["data"].as_f64() {
                                s.position = t;
                            }
                        }
                        Some("pause") => {
                            s.paused = event["data"].as_bool().unwrap_or(false);
                            event_name = if s.paused { "Pause" } else { "Unpause" };
                            s.last_report = None;
                        }
                        Some("aid") => s.audio = Tracks::jellyfin(&job.tracks.audio, &event["data"]).or(s.audio),
                        Some("sid") => s.subtitle = Tracks::jellyfin(&job.tracks.subtitle, &event["data"]),
                        _ => {}
                    }
                    if s.started && s.last_report.map(|t| t.elapsed() >= REPORT_EVERY).unwrap_or(true) {
                        s.last_report = Some(Instant::now());
                        Some((s.clone(), event_name))
                    } else {
                        None
                    }
                };
                if let Some((s, name)) = due {
                    let mut body = report_body(&s);
                    body["EventName"] = json!(name);
                    let _order = app.playback.reporting.lock().await;
                    let _ = app.jellyfin.post("/Sessions/Playing/Progress", body).await;
                }
            }
            _ => {}
        }
    }
    Ok(ended_at_end)
}

/// The current session, for the window to ask after a restart.
pub async fn status(app: &App) -> Value {
    match app.playback.current.lock().await.as_ref() {
        Some(s) => json!({
            "session": s.id, "itemId": s.item_id, "position": s.position, "paused": s.paused,
            "player": match s.player { Player::Window => "window", Player::Mpv => "mpv" },
        }),
        None => Value::Null,
    }
}

/// Stop whatever plays, telling the server, and close mpv if it was ours.
pub async fn stop_all(app: &App) {
    let current = app.playback.current.lock().await.take();
    if let Some(s) = current {
        end_session(app, &s).await;
    }
    stop_mpv(app);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_the_token_from_server_urls() {
        assert_eq!(
            strip_token("/videos/x/master.m3u8?DeviceId=a&ApiKey=secret&PlaySessionId=b"),
            "/videos/x/master.m3u8?DeviceId=a&PlaySessionId=b"
        );
        assert_eq!(strip_token("/a?api_key=1"), "/a");
        assert_eq!(strip_token("/a"), "/a");
    }

    #[test]
    fn numbers_tracks_like_players_do() {
        let streams = vec![
            json!({ "type": "Audio", "index": 1 }),
            json!({ "type": "Audio", "index": 2 }),
            json!({ "type": "Subtitle", "index": 3 }),
            json!({ "type": "Subtitle", "index": 4, "isExternal": true }),
            json!({ "type": "Subtitle", "index": 5 }),
        ];
        assert_eq!(track_ordinal(&streams, "Audio", 2), Some(2));
        assert_eq!(track_ordinal(&streams, "Subtitle", 5), Some(2));
        assert_eq!(track_ordinal(&streams, "Subtitle", 4), None);
    }

    #[test]
    fn picks_subtitles_by_mode() {
        let streams = vec![
            json!({ "type": "Audio", "index": 1, "language": "eng" }),
            json!({ "type": "Audio", "index": 2, "language": "deu" }),
            json!({ "type": "Subtitle", "index": 3, "language": "eng", "isText": false }),
            json!({ "type": "Subtitle", "index": 4, "language": "eng", "isText": true }),
            json!({ "type": "Subtitle", "index": 5, "language": "eng", "isForced": true }),
        ];
        let mut prefs = crate::config::PlaybackSettings { subtitle_language: "eng".into(), audio_language: "eng".into(), ..Default::default() };
        prefs.subtitle_mode = "always".into();
        assert_eq!(pick_subtitle(&streams, &prefs, Some(1), None), Some(4));
        prefs.subtitle_mode = "foreign".into();
        assert_eq!(pick_subtitle(&streams, &prefs, Some(2), None), Some(4));
        assert_eq!(pick_subtitle(&streams, &prefs, Some(1), None), Some(5));
        prefs.subtitle_mode = "none".into();
        assert_eq!(pick_subtitle(&streams, &prefs, Some(1), Some(3)), None);
        prefs.subtitle_mode = "default".into();
        assert_eq!(pick_subtitle(&streams, &prefs, Some(1), Some(-1)), None);
        assert_eq!(pick_audio(&streams, "deu"), Some(2));
    }

    #[test]
    fn maps_mpv_tracks_back() {
        assert_eq!(Tracks::jellyfin(&[1, 2, 5], &json!(3)), Some(5));
        assert_eq!(Tracks::jellyfin(&[1, 2], &json!(false)), None);
        assert_eq!(Tracks::jellyfin(&[1, 2], &json!(0)), None);
        assert_eq!(Tracks::jellyfin(&[1, 2], &json!(9)), None);
    }

    #[test]
    fn titles_episodes() {
        let item = json!({ "name": "Pilot", "seriesName": "Homeland", "parentIndex": 1, "index": 1 });
        assert_eq!(mpv_title(&item), "Homeland S01E01 · Pilot");
    }
}
