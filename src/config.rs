use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::paths::{self, Paths};

/// Everything Omafin remembers between runs, except the access token, which
/// lives in the keyring. Unknown or missing fields fall back to their
/// defaults so an older file always loads.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// The address used at home, tried first.
    pub server_url: String,
    pub server_enabled: bool,
    /// The address used away from home, tried when the first does not answer.
    pub external_url: String,
    pub external_enabled: bool,
    /// Who signed in. Written by sign-in, never by a settings patch.
    pub user_id: String,
    pub user_name: String,
    pub server_id: String,
    pub server_name: String,
    /// This computer, as Jellyfin's session list names it. Stable per install.
    pub device_id: String,
    pub cache_cap_mb: u64,
    pub playback: PlaybackSettings,
    /// Window preferences owned by the UI (sidebar, sort orders, …).
    pub ui: Value,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            server_url: String::new(),
            server_enabled: true,
            external_url: String::new(),
            external_enabled: false,
            user_id: String::new(),
            user_name: String::new(),
            server_id: String::new(),
            server_name: String::new(),
            device_id: String::new(),
            cache_cap_mb: 1000,
            playback: PlaybackSettings::default(),
            ui: Value::Object(Default::default()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct PlaybackSettings {
    /// "window" plays in Omafin, "mpv" hands every video to mpv.
    pub player: String,
    /// Bits per second; 0 means as much as the file needs (direct play).
    pub max_bitrate: u64,
    /// Bitrate cap away from home, where uploads are usually slower.
    pub max_bitrate_away: u64,
    /// "ask" shows a Skip button, "auto" skips, "off" does neither.
    pub skip_intro: String,
    pub skip_credits: String,
    /// Start the next episode when one ends (after a short countdown).
    pub autoplay_next: bool,
    /// Three-letter language codes; empty means the file's default.
    pub audio_language: String,
    pub subtitle_language: String,
    /// "default" follows the file and server, "always", "foreign" (only when
    /// the audio is not in your language) or "none".
    pub subtitle_mode: String,
    pub subtitle_size: u64,
    pub volume: u64,
}

impl Default for PlaybackSettings {
    fn default() -> Self {
        Self {
            player: "window".into(),
            max_bitrate: 0,
            max_bitrate_away: 8_000_000,
            skip_intro: "ask".into(),
            skip_credits: "ask".into(),
            autoplay_next: true,
            audio_language: String::new(),
            subtitle_language: String::new(),
            subtitle_mode: "default".into(),
            subtitle_size: 100,
            volume: 90,
        }
    }
}

impl PlaybackSettings {
    fn normalized(mut self) -> Self {
        if !matches!(self.player.as_str(), "window" | "mpv") {
            self.player = "window".into();
        }
        for mode in [&mut self.skip_intro, &mut self.skip_credits] {
            if !matches!(mode.as_str(), "ask" | "auto" | "off") {
                *mode = "ask".into();
            }
        }
        if !matches!(self.subtitle_mode.as_str(), "default" | "always" | "foreign" | "none") {
            self.subtitle_mode = "default".into();
        }
        for lang in [&mut self.audio_language, &mut self.subtitle_language] {
            let clean: String = lang.trim().to_ascii_lowercase().chars().filter(|c| c.is_ascii_alphabetic()).take(3).collect();
            *lang = clean;
        }
        self.max_bitrate = self.max_bitrate.min(400_000_000);
        self.max_bitrate_away = self.max_bitrate_away.min(400_000_000);
        self.subtitle_size = self.subtitle_size.clamp(50, 250);
        self.volume = self.volume.min(100);
        self
    }
}

impl Settings {
    pub fn load(paths: &Paths) -> Self {
        let settings = match std::fs::read(paths.config_file()) {
            Ok(bytes) => serde_json::from_slice::<Settings>(&bytes)
                .map(Settings::normalized)
                .unwrap_or_else(|err| {
                    eprintln!("omafin: config unreadable, using defaults: {err}");
                    Settings::default().normalized()
                }),
            Err(_) => Settings::default().normalized(),
        };
        settings
    }

    pub fn save(&self, paths: &Paths) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(self)?;
        paths::write_private(&paths.config_file(), &bytes)?;
        Ok(())
    }

    pub fn normalized(mut self) -> Self {
        self.cache_cap_mb = self.cache_cap_mb.clamp(100, 50_000);
        if !self.ui.is_object() {
            self.ui = Value::Object(Default::default());
        }
        if !valid_device_id(&self.device_id) {
            self.device_id = new_id();
        }
        if !crate::jellyfin::valid_id(&self.user_id) {
            self.user_id.clear();
        }
        self.playback = self.playback.normalized();
        self
    }

    /// Apply a partial update from the UI. Only known keys are honoured, and
    /// each is validated before anything is changed.
    pub fn apply_patch(&mut self, patch: &Value) -> Result<()> {
        let Some(patch) = patch.as_object() else {
            return Err(Error::invalid("Expected an object of settings"));
        };
        let mut next = self.clone();
        for (key, value) in patch {
            match key.as_str() {
                "serverUrl" => next.server_url = normalize_url(str_of(value)?)?,
                "externalUrl" => next.external_url = normalize_url(str_of(value)?)?,
                "serverEnabled" => next.server_enabled = bool_of(value)?,
                "externalEnabled" => next.external_enabled = bool_of(value)?,
                "cacheCapMb" => next.cache_cap_mb = u64_of(value)?,
                "ui" => {
                    let Some(obj) = value.as_object() else {
                        return Err(Error::invalid("ui must be an object"));
                    };
                    let target = next.ui.as_object_mut().expect("normalized ui");
                    for (k, v) in obj {
                        if v.is_null() {
                            target.remove(k);
                        } else {
                            target.insert(k.clone(), v.clone());
                        }
                    }
                }
                "playback" => {
                    let Some(obj) = value.as_object() else {
                        return Err(Error::invalid("playback must be an object"));
                    };
                    let p = &mut next.playback;
                    for (k, v) in obj {
                        match k.as_str() {
                            "player" => p.player = choice(v, &["window", "mpv"])?,
                            "maxBitrate" => p.max_bitrate = u64_of(v)?,
                            "maxBitrateAway" => p.max_bitrate_away = u64_of(v)?,
                            "skipIntro" => p.skip_intro = choice(v, &["ask", "auto", "off"])?,
                            "skipCredits" => p.skip_credits = choice(v, &["ask", "auto", "off"])?,
                            "autoplayNext" => p.autoplay_next = bool_of(v)?,
                            "audioLanguage" => p.audio_language = str_of(v)?.to_string(),
                            "subtitleLanguage" => p.subtitle_language = str_of(v)?.to_string(),
                            "subtitleMode" => p.subtitle_mode = choice(v, &["default", "always", "foreign", "none"])?,
                            "subtitleSize" => p.subtitle_size = u64_of(v)?,
                            "volume" => p.volume = u64_of(v)?,
                            _ => return Err(Error::invalid(format!("Unknown playback setting: {k}"))),
                        }
                    }
                }
                _ => return Err(Error::invalid(format!("Unknown setting: {key}"))),
            }
        }
        if next.server_url.is_empty() && next.external_url.is_empty() {
            next.server_enabled = true;
        }
        *self = next.normalized();
        Ok(())
    }

    /// What the UI may see: everything here, since the token is never stored in it.
    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    pub fn signed_in(&self) -> bool {
        !self.user_id.is_empty()
    }
}

pub fn new_id() -> String {
    let mut bytes = [0u8; 16];
    let _ = getrandom::fill(&mut bytes);
    hex::encode(bytes)
}

fn valid_device_id(id: &str) -> bool {
    id.len() == 32 && id.chars().all(|c| c.is_ascii_hexdigit())
}

pub fn normalize_url(raw: &str) -> Result<String> {
    let mut value = raw.trim().to_string();
    if value.is_empty() {
        return Ok(value);
    }
    if !value.contains("://") {
        value = format!("http://{value}");
    }
    let parsed = url::Url::parse(&value).map_err(|_| Error::invalid("That is not a valid server address"))?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err(Error::invalid("The server address must start with http:// or https://"));
    }
    if parsed.host_str().is_none() {
        return Err(Error::invalid("The server address has no host"));
    }
    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(Error::invalid("The server address cannot carry a query"));
    }
    let mut text = parsed.to_string();
    while text.ends_with('/') {
        text.pop();
    }
    // People paste the web client's address as often as the server's.
    for suffix in ["/web/index.html", "/web"] {
        if let Some(stripped) = text.strip_suffix(suffix) {
            text = stripped.to_string();
        }
    }
    Ok(text)
}

fn choice(value: &Value, allowed: &[&str]) -> Result<String> {
    let text = str_of(value)?;
    if allowed.contains(&text) {
        Ok(text.to_string())
    } else {
        Err(Error::invalid(format!("Expected one of {}", allowed.join(", "))))
    }
}

fn str_of(value: &Value) -> Result<&str> {
    value.as_str().ok_or_else(|| Error::invalid("Expected text"))
}

fn bool_of(value: &Value) -> Result<bool> {
    value.as_bool().ok_or_else(|| Error::invalid("Expected true or false"))
}

fn u64_of(value: &Value) -> Result<u64> {
    value
        .as_u64()
        .or_else(|| value.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
        .ok_or_else(|| Error::invalid("Expected a whole number"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalizes_server_addresses() {
        assert_eq!(normalize_url("192.168.1.10:8096").unwrap(), "http://192.168.1.10:8096");
        assert_eq!(normalize_url("https://tv.example.com/web/").unwrap(), "https://tv.example.com");
        assert_eq!(normalize_url("https://example.com/jellyfin/").unwrap(), "https://example.com/jellyfin");
        assert!(normalize_url("ftp://x").is_err());
        assert!(normalize_url("http://x/?a=1").is_err());
        assert_eq!(normalize_url("  ").unwrap(), "");
    }

    #[test]
    fn patch_rejects_unknown_keys_and_keeps_state() {
        let mut settings = Settings::default().normalized();
        assert!(settings.apply_patch(&json!({"serverUrl": "nas:8096", "bogus": 1})).is_err());
        assert_eq!(settings.server_url, "");
        settings.apply_patch(&json!({"serverUrl": "nas:8096", "playback": {"skipIntro": "auto"}})).unwrap();
        assert_eq!(settings.server_url, "http://nas:8096");
        assert_eq!(settings.playback.skip_intro, "auto");
        assert!(settings.apply_patch(&json!({"playback": {"player": "vlc"}})).is_err());
        // Sign-in fields are not patchable.
        assert!(settings.apply_patch(&json!({"userId": "x"})).is_err());
    }

    #[test]
    fn normalizes_playback() {
        let p = PlaybackSettings { audio_language: " ENG1 ".into(), subtitle_size: 9, volume: 300, ..Default::default() }.normalized();
        assert_eq!(p.audio_language, "eng");
        assert_eq!(p.subtitle_size, 50);
        assert_eq!(p.volume, 100);
    }

    #[test]
    fn device_id_is_created_once() {
        let a = Settings::default().normalized();
        assert_eq!(a.device_id.len(), 32);
        let b = a.clone().normalized();
        assert_eq!(a.device_id, b.device_id);
    }

    #[test]
    fn ui_patch_merges_and_removes() {
        let mut settings = Settings::default().normalized();
        settings.apply_patch(&json!({"ui": {"a": 1, "b": 2}})).unwrap();
        settings.apply_patch(&json!({"ui": {"a": null}})).unwrap();
        assert_eq!(settings.ui, json!({"b": 2}));
    }
}
