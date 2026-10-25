use std::fmt;

/// An error that crosses the RPC boundary. The code tells the UI what kind of
/// failure this is; the message is written for the person reading the window.
#[derive(Debug, Clone)]
pub struct Error {
    pub code: i64,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

pub const INVALID_PARAMS: i64 = -32602;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INTERNAL: i64 = -32603;
pub const NOT_CONFIGURED: i64 = -32001;
pub const UNAUTHORIZED: i64 = -32002;
pub const FORBIDDEN: i64 = -32003;
pub const NOT_FOUND: i64 = -32004;
pub const NETWORK: i64 = -32005;
pub const SERVER: i64 = -32006;
pub const KEYRING: i64 = -32007;

impl Error {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(INVALID_PARAMS, message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(INTERNAL, message)
    }

    pub fn not_configured() -> Self {
        Self::new(NOT_CONFIGURED, "Sign in to your Jellyfin server first")
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({ "code": self.code, "message": self.message })
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::internal(error.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(error: serde_json::Error) -> Self {
        Self::internal(format!("Malformed data: {error}"))
    }
}
