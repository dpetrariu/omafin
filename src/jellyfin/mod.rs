//! The Jellyfin REST client. Every request goes through `send`, which picks the
//! reachable address, attaches the session token and turns failures into
//! sentences.

pub mod profile;

use std::time::Duration;

use reqwest::{Method, StatusCode};
use serde_json::Value;
use tokio::sync::RwLock;

use crate::error::{self, Error, Result};

const PING_TIMEOUT: Duration = Duration::from_secs(4);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
pub const CLIENT: &str = "Omafin";

#[derive(Debug, Clone, Default)]
struct Conn {
    lan: Option<String>,
    wan: Option<String>,
    token: Option<String>,
    /// The server signed in to. An address whose server reports another Id
    /// never gets the token: on someone else's network, a different machine
    /// can answer at the home address.
    server_id: Option<String>,
    active: Option<String>,
    route: &'static str,
}

pub struct Jellyfin {
    http: reqwest::Client,
    conn: RwLock<Conn>,
    device_id: std::sync::RwLock<String>,
    device_name: String,
}

/// Which address answered.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Route {
    pub url: String,
    pub route: &'static str,
}

impl Jellyfin {
    pub fn new(device_id: String) -> Self {
        let http = reqwest::Client::builder()
            .user_agent(concat!("Omafin/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(8))
            .pool_idle_timeout(Duration::from_secs(60))
            .build()
            .expect("http client");
        Self {
            http,
            conn: RwLock::new(Conn::default()),
            device_id: std::sync::RwLock::new(device_id),
            device_name: device_name(),
        }
    }

    pub fn device_id(&self) -> String {
        self.device_id.read().unwrap().clone()
    }

    /// The `Authorization` value Jellyfin expects from a client. Without a
    /// token it still names the device, which sign-in needs.
    pub fn authorization(&self, token: Option<&str>) -> String {
        let mut value = format!(
            "MediaBrowser Client=\"{CLIENT}\", Device=\"{}\", DeviceId=\"{}\", Version=\"{}\"",
            header_safe(&self.device_name),
            self.device_id(),
            env!("CARGO_PKG_VERSION")
        );
        if let Some(token) = token {
            value.push_str(&format!(", Token=\"{}\"", header_safe(token)));
        }
        value
    }

    pub async fn configure(
        &self,
        lan: Option<String>,
        wan: Option<String>,
        token: Option<String>,
        server_id: Option<String>,
    ) {
        let mut conn = self.conn.write().await;
        conn.lan = lan.filter(|s| !s.is_empty());
        conn.wan = wan.filter(|s| !s.is_empty());
        conn.token = token.filter(|s| !s.is_empty());
        conn.server_id = server_id.filter(|s| !s.is_empty());
        conn.active = None;
    }

    pub async fn set_urls(&self, lan: Option<String>, wan: Option<String>) {
        let mut conn = self.conn.write().await;
        conn.lan = lan.filter(|s| !s.is_empty());
        conn.wan = wan.filter(|s| !s.is_empty());
        conn.active = None;
    }

    pub async fn set_token(&self, token: Option<String>) {
        let mut conn = self.conn.write().await;
        conn.token = token.filter(|s| !s.is_empty());
        conn.active = None;
    }

    pub async fn has_token(&self) -> bool {
        self.conn.read().await.token.is_some()
    }

    pub async fn is_configured(&self) -> bool {
        let conn = self.conn.read().await;
        conn.token.is_some() && (conn.lan.is_some() || conn.wan.is_some())
    }

    pub async fn route(&self) -> Option<Route> {
        let conn = self.conn.read().await;
        conn.active.clone().map(|url| Route { url, route: conn.route })
    }

    /// Forget the address that answered last, so the next request looks again.
    pub async fn reset_route(&self) {
        self.conn.write().await.active = None;
    }

    /// The server's public information, or None when nothing Jellyfin-like
    /// answered at that address.
    pub async fn public_info(&self, base: &str) -> Option<Value> {
        let url = format!("{base}/System/Info/Public");
        let response = self.http.get(&url).timeout(PING_TIMEOUT).send().await.ok()?;
        if !response.status().is_success() {
            return None;
        }
        let value: Value = response.json().await.ok()?;
        value.get("Id").and_then(|v| v.as_str()).filter(|s| !s.is_empty())?;
        Some(value)
    }

    /// The base address and token to use now. Home first, then away.
    pub async fn base(&self) -> Result<(String, String)> {
        {
            let conn = self.conn.read().await;
            let Some(token) = conn.token.clone() else {
                return Err(Error::not_configured());
            };
            if let Some(active) = conn.active.clone() {
                return Ok((active, token));
            }
            if conn.lan.is_none() && conn.wan.is_none() {
                return Err(Error::not_configured());
            }
        }
        let (lan, wan, token, server_id) = {
            let conn = self.conn.read().await;
            (conn.lan.clone(), conn.wan.clone(), conn.token.clone().unwrap_or_default(), conn.server_id.clone())
        };
        let mut stranger = None;
        for (candidate, route) in [(lan, "lan"), (wan, "wan")] {
            if let Some(url) = candidate {
                let Some(info) = self.public_info(&url).await else { continue };
                if !same_server(&info, server_id.as_deref()) {
                    stranger = Some(url);
                    continue;
                }
                let mut conn = self.conn.write().await;
                conn.active = Some(url.clone());
                conn.route = route;
                return Ok((url, token));
            }
        }
        if let Some(url) = stranger {
            return Err(Error::new(
                error::NETWORK,
                format!(
                    "A different Jellyfin server answers at {url}, so Omafin did not send it your session. If you moved to a new server, sign in to it again"
                ),
            ));
        }
        Err(Error::new(error::NETWORK, "Could not reach the Jellyfin server"))
    }

    pub async fn get(&self, path: &str) -> Result<Value> {
        self.send(Method::GET, path, None).await
    }

    pub async fn post(&self, path: &str, body: Value) -> Result<Value> {
        self.send(Method::POST, path, Some(body)).await
    }

    pub async fn delete(&self, path: &str) -> Result<Value> {
        self.send(Method::DELETE, path, None).await
    }

    pub async fn send(&self, method: Method, path: &str, body: Option<Value>) -> Result<Value> {
        let (base, token) = self.base().await?;
        let mut request = self
            .http
            .request(method, format!("{base}{path}"))
            .header("Authorization", self.authorization(Some(&token)))
            .header("Accept", "application/json")
            .timeout(REQUEST_TIMEOUT);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = match request.send().await {
            Ok(response) => response,
            Err(err) => {
                self.reset_route().await;
                return Err(network_error(&err));
            }
        };
        read_json(response).await
    }

    /// A raw response for media, keeping the server's headers. `extra` carries
    /// Range through unchanged.
    pub async fn raw(&self, path: &str, extra: &[(&str, String)]) -> Result<reqwest::Response> {
        self.raw_with(Method::GET, path, extra).await
    }

    /// The same, as a HEAD when the player only asks about a stream: a GET
    /// of a playlist would start a transcode on the server.
    pub async fn raw_with(&self, method: Method, path: &str, extra: &[(&str, String)]) -> Result<reqwest::Response> {
        let (base, token) = self.base().await?;
        let mut request = self
            .http
            .request(method, format!("{base}{path}"))
            .header("Authorization", self.authorization(Some(&token)));
        for (name, value) in extra {
            request = request.header(*name, value);
        }
        match request.send().await {
            Ok(response) if response.status().is_success() || response.status() == StatusCode::NOT_MODIFIED => {
                Ok(response)
            }
            Ok(response) => Err(status_error(response.status(), &response.text().await.unwrap_or_default())),
            Err(err) => {
                self.reset_route().await;
                Err(network_error(&err))
            }
        }
    }

    /// A request to an address that is not saved yet, for signing in.
    pub async fn unsaved(&self, method: Method, url: &str, token: Option<&str>, body: Option<Value>) -> Result<Value> {
        let mut request = self
            .http
            .request(method, url)
            .header("Authorization", self.authorization(token))
            .header("Accept", "application/json")
            .timeout(Duration::from_secs(20));
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|e| network_error(&e))?;
        read_json(response).await
    }
}

fn device_name() -> String {
    let host = std::fs::read_to_string("/etc/hostname").unwrap_or_default();
    let host = host.trim();
    if host.is_empty() { "Omarchy".into() } else { format!("Omarchy ({host})") }
}

/// Quotes and control characters would end the header's quoted value.
fn header_safe(text: &str) -> String {
    text.chars().filter(|c| *c != '"' && *c != '\\' && !c.is_control()).take(120).collect()
}

pub async fn read_json(response: reqwest::Response) -> Result<Value> {
    let status = response.status();
    let text = response.text().await.map_err(|e| network_error(&e))?;
    if !status.is_success() {
        return Err(status_error(status, &text));
    }
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&text).map_err(|_| Error::new(error::SERVER, "Jellyfin sent a response Omafin could not read"))
}

fn server_message(body: &str) -> Option<String> {
    let trimmed = body.trim();
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        for key in ["detail", "title", "message", "Message"] {
            if let Some(text) = value.get(key).and_then(|v| v.as_str()) {
                return Some(text.to_string());
            }
        }
        return None;
    }
    // Jellyfin sometimes answers with a bare sentence.
    if !trimmed.is_empty() && trimmed.len() < 200 && !trimmed.starts_with('<') {
        return Some(trimmed.to_string());
    }
    None
}

pub fn status_error(status: StatusCode, body: &str) -> Error {
    let detail = server_message(body);
    match status {
        StatusCode::UNAUTHORIZED => Error::new(
            error::UNAUTHORIZED,
            "Jellyfin signed this computer out. Sign in again in Settings",
        ),
        StatusCode::FORBIDDEN => Error::new(
            error::FORBIDDEN,
            detail.unwrap_or_else(|| "Your Jellyfin account is not allowed to do this".to_string()),
        ),
        StatusCode::NOT_FOUND => Error::new(error::NOT_FOUND, "Not found on the server"),
        s if s.is_client_error() => Error::new(
            error::INVALID_PARAMS,
            detail.unwrap_or_else(|| format!("Jellyfin refused the request ({})", s.as_u16())),
        ),
        s => Error::new(
            error::SERVER,
            format!("Jellyfin had a problem ({}){}", s.as_u16(), detail.map(|d| format!(": {d}")).unwrap_or_default()),
        ),
    }
}

pub fn network_error(err: &reqwest::Error) -> Error {
    if err.is_timeout() {
        Error::new(error::NETWORK, "The Jellyfin server took too long to answer")
    } else if err.is_connect() {
        Error::new(error::NETWORK, "Could not reach the Jellyfin server")
    } else {
        // Without the URL: a query can hold a secret (Quick Connect's).
        let mut text = err.to_string();
        if let Some(url) = err.url() {
            text = text.replace(&format!(" for url ({url})"), "").replace(url.as_str(), "the server");
        }
        Error::new(error::NETWORK, format!("Network problem: {text}"))
    }
}

/// Percent-encode one query value.
pub fn q(value: &str) -> String {
    percent_encoding::utf8_percent_encode(value, percent_encoding::NON_ALPHANUMERIC).to_string()
}

/// Whether `info` (from /System/Info/Public) is the server signed in to. With
/// no saved Id (a sign-in from before Omafin kept one) any server counts.
pub fn same_server(info: &Value, expected: Option<&str>) -> bool {
    match expected {
        // Ids compare as GUIDs: with or without dashes, in any case.
        Some(id) => {
            let norm = |s: &str| s.chars().filter(|c| *c != '-').collect::<String>().to_ascii_lowercase();
            info.get("Id").and_then(|v| v.as_str()).map(norm) == Some(norm(id))
        }
        None => true,
    }
}

/// Jellyfin ids are GUIDs, written as 32 hex digits or with dashes; anything
/// else never reaches a URL path.
pub fn valid_id(id: &str) -> bool {
    match id.len() {
        32 => id.chars().all(|c| c.is_ascii_hexdigit()),
        36 => id.chars().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        }),
        _ => false,
    }
}

pub fn require_id(id: &str) -> Result<&str> {
    if valid_id(id) { Ok(id) } else { Err(Error::invalid("Not a valid Jellyfin id")) }
}

/// Jellyfin counts time in ticks of 100 ns.
pub const TICKS_PER_SECOND: i64 = 10_000_000;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_ids() {
        assert!(valid_id("b5bc49c0d5bc4cde8391f85fc2d13667"));
        assert!(valid_id("95d338b7-e7d1-4a25-89e5-869b16fca112"));
        assert!(!valid_id("../../etc/passwd"));
        assert!(!valid_id("b5bc49c0d5bc4cde8391f85fc2d1366z"));
    }

    #[test]
    fn sends_the_token_only_to_the_signed_in_server() {
        let ours = serde_json::json!({ "Id": "b5bc49c0d5bc4cde8391f85fc2d13667" });
        let theirs = serde_json::json!({ "Id": "0123456789abcdef0123456789abcdef" });
        assert!(same_server(&ours, Some("b5bc49c0d5bc4cde8391f85fc2d13667")));
        assert!(!same_server(&theirs, Some("b5bc49c0d5bc4cde8391f85fc2d13667")));
        assert!(!same_server(&serde_json::json!({}), Some("b5bc49c0d5bc4cde8391f85fc2d13667")));
        assert!(same_server(&theirs, None));
        assert!(same_server(&serde_json::json!({ "Id": "b5bc49c0-d5bc-4cde-8391-f85fc2d13667" }), Some("B5BC49C0D5BC4CDE8391F85FC2D13667")));
    }

    #[test]
    fn explains_statuses() {
        assert_eq!(status_error(StatusCode::UNAUTHORIZED, "").code, error::UNAUTHORIZED);
        let e = status_error(StatusCode::BAD_REQUEST, "Invalid username or password entered.");
        assert!(e.message.contains("Invalid username"));
        let e = status_error(StatusCode::BAD_REQUEST, r#"{"title":"One or more validation errors occurred."}"#);
        assert!(e.message.contains("validation"));
    }

    #[test]
    fn authorization_header_is_quoted_safely() {
        let jf = Jellyfin::new("0123456789abcdef0123456789abcdef".into());
        let header = jf.authorization(Some("tok\"en"));
        assert!(header.starts_with("MediaBrowser Client=\"Omafin\""));
        assert!(header.contains("DeviceId=\"0123456789abcdef0123456789abcdef\""));
        assert!(header.ends_with("Token=\"token\""));
    }
}
