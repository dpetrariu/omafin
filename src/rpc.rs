//! Newline-delimited JSON-RPC 2.0 over stdin/stdout. Requests run
//! concurrently; one writer task owns stdout so frames never interleave.

use std::sync::Arc;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::app::App;
use crate::error::{Error, INVALID_PARAMS};

const MAX_FRAME: usize = 4 * 1024 * 1024;

#[derive(Clone)]
pub struct Notifier {
    tx: mpsc::UnboundedSender<String>,
}

impl Notifier {
    pub fn channel() -> (Notifier, mpsc::UnboundedReceiver<String>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Notifier { tx }, rx)
    }

    pub fn notify(&self, method: &str, params: Value) {
        let frame = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        let _ = self.tx.send(frame.to_string());
    }

    fn respond(&self, id: Value, result: std::result::Result<Value, Error>) {
        let frame = match result {
            Ok(value) => json!({ "jsonrpc": "2.0", "id": id, "result": value }),
            Err(err) => json!({ "jsonrpc": "2.0", "id": id, "error": err.to_json() }),
        };
        let _ = self.tx.send(frame.to_string());
    }
}

pub async fn serve(app: Arc<App>, mut out: mpsc::UnboundedReceiver<String>) {
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = out.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.write_all(b"\n").await.is_err() {
                break;
            }
            let _ = stdout.flush().await;
        }
    });

    let mut reader = BufReader::new(tokio::io::stdin());
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if line.len() > MAX_FRAME {
            continue;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(trimmed) else {
            app.notifier.respond(Value::Null, Err(Error::new(-32700, "Parse error")));
            continue;
        };
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        let Some(method) = message.get("method").and_then(|m| m.as_str()).map(|s| s.to_string()) else {
            app.notifier.respond(id, Err(Error::new(INVALID_PARAMS, "Missing method")));
            continue;
        };
        let params = message.get("params").cloned().unwrap_or(Value::Object(Default::default()));
        if method == "system.shutdown" {
            app.notifier.respond(id, Ok(Value::Bool(true)));
            break;
        }
        let app = app.clone();
        tokio::spawn(async move {
            let result = crate::methods::dispatch(&app, &method, &params).await;
            if !id.is_null() {
                app.notifier.respond(id, result);
            }
        });
    }
    // Give in-flight answers a moment to reach stdout before the process ends.
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
    writer.abort();
}
