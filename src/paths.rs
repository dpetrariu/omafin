use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// Where Omafin keeps its files. Everything is private to the user: the
/// configuration names the server and the account.
#[derive(Debug, Clone)]
pub struct Paths {
    pub config_dir: PathBuf,
    pub data_dir: PathBuf,
    pub cache_dir: PathBuf,
}

fn xdg(var: &str, fallback: &str) -> PathBuf {
    match std::env::var_os(var) {
        Some(value) if Path::new(&value).is_absolute() => PathBuf::from(value),
        _ => home().join(fallback),
    }
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

impl Paths {
    pub fn from_env() -> Self {
        // A test or a second profile can point every directory elsewhere at once.
        if let Some(root) = std::env::var_os("OMAFIN_HOME") {
            let root = PathBuf::from(root);
            return Self {
                config_dir: root.join("config"),
                data_dir: root.join("data"),
                cache_dir: root.join("cache"),
            };
        }
        Self {
            config_dir: xdg("XDG_CONFIG_HOME", ".config").join("omafin"),
            data_dir: xdg("XDG_DATA_HOME", ".local/share").join("omafin"),
            cache_dir: xdg("XDG_CACHE_HOME", ".cache").join("omafin"),
        }
    }

    pub fn ensure(&self) -> std::io::Result<()> {
        for dir in [&self.config_dir, &self.data_dir, &self.cache_dir] {
            fs::create_dir_all(dir)?;
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }

    pub fn config_file(&self) -> PathBuf {
        self.config_dir.join("config.json")
    }

    pub fn token_fallback_file(&self) -> PathBuf {
        self.config_dir.join("token")
    }

    /// Where mpv's control socket goes while it plays.
    pub fn runtime_dir(&self) -> PathBuf {
        match std::env::var_os("XDG_RUNTIME_DIR") {
            Some(dir) if Path::new(&dir).is_absolute() && std::env::var_os("OMAFIN_HOME").is_none() => PathBuf::from(dir).join("omafin"),
            _ => self.cache_dir.join("run"),
        }
    }

    /// The list of downloads (the files themselves live in the download folder).
    pub fn downloads_index(&self) -> PathBuf {
        self.data_dir.join("downloads.json")
    }

    /// Where downloads go unless Settings says otherwise: an Omafin folder
    /// in the desktop's Videos folder. A test (OMAFIN_HOME) keeps them in
    /// its own folder, never the real one.
    pub fn default_downloads(&self) -> PathBuf {
        if let Some(root) = std::env::var_os("OMAFIN_HOME") {
            return PathBuf::from(root).join("videos").join("Omafin");
        }
        let videos = std::process::Command::new("xdg-user-dir")
            .arg("VIDEOS")
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()))
            .filter(|p| p.is_absolute() && p != &home())
            .unwrap_or_else(|| home().join("Videos"));
        videos.join("Omafin")
    }

    pub fn media_cache(&self) -> PathBuf {
        self.cache_dir.join("media")
    }
}

/// Replace a file in one step, readable only by its owner, so a crash never
/// leaves half a configuration behind.
pub fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    let mut nonce = [0u8; 6];
    let _ = getrandom::fill(&mut nonce);
    let tmp = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
        hex::encode(nonce)
    ));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// Expand a leading `~/` the way a person typing a folder expects.
pub fn expand_home(raw: &str) -> PathBuf {
    let trimmed = raw.trim();
    if trimmed == "~" {
        return home();
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        return home().join(rest);
    }
    PathBuf::from(trimmed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_write_is_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("x.json");
        write_private(&file, b"{}").unwrap();
        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert_eq!(fs::read(&file).unwrap(), b"{}");
    }
}
