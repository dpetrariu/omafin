use std::time::Duration;

use crate::error::{Error, KEYRING, Result};
use crate::paths::{self, Paths};

const SERVICE: &str = "omafin";
const ACCOUNT: &str = "access_token";
const LABEL: &str = "Omafin Jellyfin session";
const TIMEOUT: Duration = Duration::from_secs(8);

/// Where the token ended up when it was saved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Storage {
    Keyring,
    File,
}

impl Storage {
    pub fn as_str(self) -> &'static str {
        match self {
            Storage::Keyring => "keyring",
            Storage::File => "file",
        }
    }
}

async fn keyring() -> Result<oo7::Keyring> {
    match tokio::time::timeout(TIMEOUT, oo7::Keyring::new()).await {
        Ok(Ok(keyring)) => Ok(keyring),
        Ok(Err(err)) => Err(Error::new(KEYRING, format!("The keyring is unavailable: {err}"))),
        Err(_) => Err(Error::new(KEYRING, "The keyring did not answer")),
    }
}

async fn lookup() -> Result<Option<String>> {
    let keyring = keyring().await?;
    let _ = tokio::time::timeout(TIMEOUT, keyring.unlock()).await;
    let attributes = vec![("service", SERVICE), ("account", ACCOUNT)];
    let items = tokio::time::timeout(TIMEOUT, keyring.search_items(&attributes))
        .await
        .map_err(|_| Error::new(KEYRING, "The keyring did not answer"))?
        .map_err(|err| Error::new(KEYRING, format!("Keyring search failed: {err}")))?;
    for item in items {
        if let Ok(secret) = item.secret().await {
            let token = clean_token(&String::from_utf8_lossy(&secret));
            if !token.is_empty() {
                return Ok(Some(token));
            }
        }
    }
    Ok(None)
}

pub fn clean_token(raw: &str) -> String {
    raw.chars().filter(|c| !c.is_whitespace()).collect()
}

pub fn valid_token_shape(token: &str) -> bool {
    !token.is_empty() && token.len() <= 256 && token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// A test or second profile (OMAFIN_HOME) never touches the real keyring.
fn sandboxed() -> bool {
    std::env::var_os("OMAFIN_HOME").is_some()
}

pub async fn load(paths: &Paths) -> Option<String> {
    let found = if sandboxed() { Ok(None) } else { lookup().await };
    match found {
        Ok(Some(token)) => return Some(token),
        Ok(None) => {}
        Err(err) => eprintln!("omafin: {err}"),
    }
    std::fs::read_to_string(paths.token_fallback_file())
        .ok()
        .map(|text| clean_token(&text))
        .filter(|token| valid_token_shape(token))
}

pub async fn store(paths: &Paths, token: &str) -> Result<Storage> {
    if sandboxed() {
        paths::write_private(&paths.token_fallback_file(), token.as_bytes())?;
        return Ok(Storage::File);
    }
    let saved = async {
        let keyring = keyring().await?;
        let attributes = vec![("service", SERVICE), ("account", ACCOUNT)];
        tokio::time::timeout(TIMEOUT, keyring.create_item(LABEL, &attributes, token.as_bytes(), true))
            .await
            .map_err(|_| Error::new(KEYRING, "The keyring did not answer"))?
            .map_err(|err| Error::new(KEYRING, format!("Saving to the keyring failed: {err}")))
    }
    .await;
    match saved {
        Ok(()) => {
            let _ = std::fs::remove_file(paths.token_fallback_file());
            Ok(Storage::Keyring)
        }
        Err(err) => {
            eprintln!("omafin: {err}; keeping the session in a private file instead");
            paths::write_private(&paths.token_fallback_file(), token.as_bytes())?;
            Ok(Storage::File)
        }
    }
}

pub async fn delete(paths: &Paths) {
    if sandboxed() {
        let _ = std::fs::remove_file(paths.token_fallback_file());
        return;
    }
    if let Ok(keyring) = keyring().await {
        let attributes = vec![("service", SERVICE), ("account", ACCOUNT)];
        let _ = tokio::time::timeout(TIMEOUT, keyring.delete(&attributes)).await;
    }
    let _ = std::fs::remove_file(paths.token_fallback_file());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_tokens() {
        assert_eq!(clean_token(" abc\n def "), "abcdef");
        assert!(valid_token_shape("2d7132d515d84ab8a488f1fdd4f0d733"));
        assert!(!valid_token_shape("bad token"));
        assert!(!valid_token_shape("a\"b"));
        assert!(!valid_token_shape(""));
    }
}
