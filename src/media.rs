//! A small HTTP server on 127.0.0.1 that QML images, the video player and
//! mpv load from. It adds the session token, so the token never reaches QML
//! or a command line, keeps posters on disk, and passes Range requests and
//! HLS playlists through for video.
//!
//! Every path starts with a random token: another user on the same machine
//! can connect to the port, but cannot use the session without the token.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use futures_util::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;

use crate::jellyfin::{Jellyfin, valid_id};

const MAX_HEAD: usize = 16 * 1024;

pub struct Media {
    pub port: u16,
    pub token: String,
    cache_dir: PathBuf,
    jellyfin: Arc<Jellyfin>,
    fetches: Semaphore,
}

#[derive(Debug, PartialEq)]
enum Route {
    /// A poster, backdrop, thumb or logo at a width, cached by its tag.
    Image { id: String, kind: &'static str, tag: String, width: u32 },
    /// A path on the server under /Videos/{id}/: the file, HLS playlists and
    /// segments, subtitles and trickplay tiles.
    Server { path: String, cache: bool },
}

impl Media {
    pub async fn start(jellyfin: Arc<Jellyfin>, cache_dir: PathBuf) -> std::io::Result<Arc<Media>> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|e| std::io::Error::other(e.to_string()))?;
        std::fs::create_dir_all(&cache_dir)?;
        let media = Arc::new(Media {
            port,
            token: hex::encode(bytes),
            cache_dir,
            jellyfin,
            fetches: Semaphore::new(12),
        });
        let server = media.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, peer)) = listener.accept().await else { continue };
                if !peer.ip().is_loopback() {
                    continue;
                }
                let media = server.clone();
                tokio::spawn(async move {
                    let _ = media.handle(stream).await;
                });
            }
        });
        Ok(media)
    }

    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}/{}", self.port, self.token)
    }

    async fn handle(&self, mut stream: TcpStream) -> std::io::Result<()> {
        let mut head = Vec::with_capacity(1024);
        let mut buf = [0u8; 2048];
        loop {
            let n = tokio::time::timeout(Duration::from_secs(10), stream.read(&mut buf))
                .await
                .map_err(|_| std::io::Error::other("timeout"))??;
            if n == 0 {
                return Ok(());
            }
            head.extend_from_slice(&buf[..n]);
            if head.windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
            if head.len() > MAX_HEAD {
                return respond_status(&mut stream, 431, "Request Header Fields Too Large").await;
            }
        }
        let text = String::from_utf8_lossy(&head).to_string();
        let mut lines = text.split("\r\n");
        let request_line = lines.next().unwrap_or("");
        let mut parts = request_line.split(' ');
        let method = parts.next().unwrap_or("");
        let target = parts.next().unwrap_or("");
        let mut range = None;
        for line in lines {
            if let Some((name, value)) = line.split_once(':') {
                if name.trim().eq_ignore_ascii_case("range") {
                    range = Some(value.trim().to_string());
                }
            }
        }
        if method != "GET" && method != "HEAD" {
            return respond_status(&mut stream, 405, "Method Not Allowed").await;
        }
        let Some(route) = parse_target(target, &self.token) else {
            return respond_status(&mut stream, 404, "Not Found").await;
        };
        let head_only = method == "HEAD";
        match route {
            Route::Image { id, kind, tag, width } => {
                let upstream = format!("/Items/{id}/Images/{kind}?tag={tag}&fillWidth={width}&quality=90");
                let file = self.cache_path("image", &id, &format!("{kind}-{width}-{tag}"));
                self.serve_cached(&mut stream, &upstream, &file, head_only).await
            }
            Route::Server { path, cache: true } => {
                let digest = hex::encode(&sha1_bytes(path.as_bytes())[..12]);
                let file = self.cache_path("tiles", &digest, "1");
                self.serve_cached(&mut stream, &path, &file, head_only).await
            }
            Route::Server { path, cache: false } => self.serve_stream(&mut stream, &path, range, head_only).await,
        }
    }

    fn cache_path(&self, kind: &str, id: &str, variant: &str) -> PathBuf {
        let variant: String = variant
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .take(60)
            .collect();
        self.cache_dir.join(kind).join(&id[..2]).join(format!("{id}-{variant}"))
    }

    async fn serve_cached(&self, stream: &mut TcpStream, upstream: &str, file: &Path, head_only: bool) -> std::io::Result<()> {
        if let Ok(bytes) = tokio::fs::read(file).await {
            touch(file);
            return respond_bytes(stream, &bytes, head_only).await;
        }
        let permit = self.fetches.acquire().await;
        // Another request may have filled the cache while this one waited.
        if let Ok(bytes) = tokio::fs::read(file).await {
            drop(permit);
            return respond_bytes(stream, &bytes, head_only).await;
        }
        let response = match self.jellyfin.raw(upstream, &[]).await {
            Ok(response) => response,
            Err(err) => {
                drop(permit);
                let code = if err.code == crate::error::NOT_FOUND { 404 } else { 502 };
                return respond_status(stream, code, "Upstream").await;
            }
        };
        let bytes = match response.bytes().await {
            Ok(bytes) => bytes,
            Err(_) => {
                drop(permit);
                return respond_status(stream, 502, "Upstream").await;
            }
        };
        drop(permit);
        if !bytes.is_empty() {
            if let Some(parent) = file.parent() {
                let _ = tokio::fs::create_dir_all(parent).await;
            }
            let tmp = file.with_extension("part");
            if tokio::fs::write(&tmp, &bytes).await.is_ok() {
                let _ = tokio::fs::rename(&tmp, file).await;
            }
        }
        respond_bytes(stream, &bytes, head_only).await
    }

    async fn serve_stream(&self, stream: &mut TcpStream, upstream: &str, range: Option<String>, head_only: bool) -> std::io::Result<()> {
        let mut extra = Vec::new();
        if let Some(range) = range.filter(|r| r.len() < 200 && r.starts_with("bytes=")) {
            extra.push(("Range", range));
        }
        let response = match self.jellyfin.raw(upstream, &extra).await {
            Ok(response) => response,
            Err(_) => return respond_status(stream, 502, "Upstream").await,
        };
        let status = response.status();
        let playlist = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .map(|t| t.contains("mpegurl"))
            .unwrap_or(false)
            || upstream.split('?').next().unwrap_or("").ends_with(".m3u8");
        if playlist {
            // Playlists name their segments with the token in the query;
            // the proxy adds it itself, so it is taken out on the way past.
            let text = response.text().await.unwrap_or_default();
            let body = clean_playlist(&text);
            let head = format!(
                "HTTP/1.1 {} {}\r\ncontent-type: application/vnd.apple.mpegurl\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n",
                status.as_u16(),
                status.canonical_reason().unwrap_or("OK"),
                body.len()
            );
            stream.write_all(head.as_bytes()).await?;
            if !head_only {
                stream.write_all(body.as_bytes()).await?;
            }
            return stream.shutdown().await;
        }
        let mut head = format!("HTTP/1.1 {} {}\r\n", status.as_u16(), status.canonical_reason().unwrap_or("OK"));
        for name in ["content-type", "content-length", "content-range", "accept-ranges", "last-modified", "etag"] {
            if let Some(value) = response.headers().get(name).and_then(|v| v.to_str().ok()) {
                if !value.contains('\r') && !value.contains('\n') {
                    head.push_str(&format!("{name}: {value}\r\n"));
                }
            }
        }
        if response.headers().get("accept-ranges").is_none() {
            head.push_str("accept-ranges: bytes\r\n");
        }
        head.push_str("cache-control: no-store\r\nconnection: close\r\n\r\n");
        stream.write_all(head.as_bytes()).await?;
        if head_only {
            return stream.shutdown().await;
        }
        let mut body = response.bytes_stream();
        while let Some(chunk) = body.next().await {
            match chunk {
                Ok(chunk) => stream.write_all(&chunk).await?,
                Err(_) => break,
            }
        }
        stream.shutdown().await
    }

    /// Bytes on disk, for the settings page.
    pub fn cache_size(&self) -> u64 {
        walkdir::WalkDir::new(&self.cache_dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
            .filter_map(|e| e.metadata().ok())
            .map(|m| m.len())
            .sum()
    }

    pub fn clear(&self) -> u64 {
        let size = self.cache_size();
        for kind in ["image", "tiles"] {
            let _ = std::fs::remove_dir_all(self.cache_dir.join(kind));
        }
        size
    }

    /// Drop the least recently used files until the cache is back under 80 %
    /// of its cap.
    pub fn prune(&self, cap_bytes: u64) -> u64 {
        let mut files: Vec<(SystemTime, u64, PathBuf)> = walkdir::WalkDir::new(&self.cache_dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
            .filter_map(|e| {
                let meta = e.metadata().ok()?;
                Some((meta.modified().unwrap_or(SystemTime::UNIX_EPOCH), meta.len(), e.into_path()))
            })
            .collect();
        let mut total: u64 = files.iter().map(|f| f.1).sum();
        if total <= cap_bytes {
            return 0;
        }
        files.sort_by_key(|f| f.0);
        let target = cap_bytes / 10 * 8;
        let mut removed = 0;
        for (_, len, path) in files {
            if total <= target {
                break;
            }
            if std::fs::remove_file(&path).is_ok() {
                total = total.saturating_sub(len);
                removed += len;
            }
        }
        removed
    }
}

fn touch(file: &Path) {
    // Recency drives pruning; an hour's precision is plenty and saves writes.
    if let Ok(meta) = std::fs::metadata(file) {
        let stale = meta
            .modified()
            .ok()
            .and_then(|m| m.elapsed().ok())
            .map(|age| age > Duration::from_secs(3600))
            .unwrap_or(true);
        if stale {
            if let Ok(f) = std::fs::File::options().append(true).open(file) {
                let _ = f.set_modified(SystemTime::now());
            }
        }
    }
}

fn parse_target(target: &str, token: &str) -> Option<Route> {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let path = path.trim_start_matches('/');
    let (given, rest) = path.split_once('/')?;
    if !constant_time_eq(given.as_bytes(), token.as_bytes()) {
        return None;
    }
    let param = |name: &str| -> String {
        query
            .split('&')
            .filter_map(|kv| kv.split_once('='))
            .find(|(k, _)| *k == name)
            .map(|(_, v)| v.to_string())
            .unwrap_or_default()
    };
    let (kind, rest) = rest.split_once('/')?;
    match kind {
        "img" => {
            let mut segments = rest.split('/');
            let id = segments.next()?.to_string();
            let image = match segments.next()? {
                "Primary" => "Primary",
                "Backdrop" => "Backdrop",
                "Thumb" => "Thumb",
                "Logo" => "Logo",
                "Banner" => "Banner",
                _ => return None,
            };
            if segments.next().is_some() || !valid_id(&id) {
                return None;
            }
            let tag = param("tag");
            if tag.is_empty() || tag.len() > 64 || !tag.chars().all(|c| c.is_ascii_alphanumeric()) {
                return None;
            }
            // A few widths only, so the cache holds each picture a few times at most.
            let asked: u32 = param("w").parse().unwrap_or(400);
            let width = [160, 240, 320, 400, 600, 800, 1200, 1920, 2560, 3840]
                .into_iter()
                .find(|w| *w >= asked)
                .unwrap_or(3840);
            Some(Route::Image { id, kind: image, tag, width })
        }
        "jf" => {
            let mut segments = rest.split('/');
            let root = segments.next()?;
            if root != "Videos" && root != "videos" {
                return None;
            }
            let id = segments.next()?;
            if !valid_id(id) {
                return None;
            }
            let tail: Vec<&str> = segments.collect();
            if tail.is_empty()
                || tail.iter().any(|s| s.is_empty() || *s == "." || *s == ".." || s.contains('%') || s.contains('\\'))
            {
                return None;
            }
            if !query.chars().all(|c| c.is_ascii_graphic()) {
                return None;
            }
            let clean = crate::playback::strip_token(&format!("/{root}/{id}/{}?{query}", tail.join("/")));
            let cache = tail.first() == Some(&"Trickplay") && tail.last().map(|t| t.ends_with(".jpg")).unwrap_or(false);
            Some(Route::Server { path: clean, cache })
        }
        _ => None,
    }
}

/// Take the token out of every URI line of an HLS playlist.
fn clean_playlist(text: &str) -> String {
    text.lines()
        .map(|line| {
            if line.starts_with('#') || line.trim().is_empty() {
                line.to_string()
            } else {
                crate::playback::strip_token(line.trim())
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

fn sha1_bytes(data: &[u8]) -> Vec<u8> {
    use sha1::Digest;
    sha1::Sha1::digest(data).to_vec()
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn sniff(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else if bytes.starts_with(b"\x89PNG") {
        "image/png"
    } else if bytes.starts_with(b"<svg") || bytes.starts_with(b"<?xml") {
        "image/svg+xml"
    } else {
        "application/octet-stream"
    }
}

async fn respond_bytes(stream: &mut TcpStream, bytes: &[u8], head_only: bool) -> std::io::Result<()> {
    let head = format!(
        "HTTP/1.1 200 OK\r\ncontent-type: {}\r\ncontent-length: {}\r\ncache-control: private, max-age=86400\r\nconnection: close\r\n\r\n",
        sniff(bytes),
        bytes.len()
    );
    stream.write_all(head.as_bytes()).await?;
    if !head_only {
        stream.write_all(bytes).await?;
    }
    stream.shutdown().await
}

async fn respond_status(stream: &mut TcpStream, code: u16, reason: &str) -> std::io::Result<()> {
    let head = format!("HTTP/1.1 {code} {reason}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
    stream.write_all(head.as_bytes()).await?;
    stream.shutdown().await
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "0123456789abcdef0123456789abcdef";
    const ID: &str = "47dd9fbce5a1b0ac647f37f0a3c4bf8f";

    #[test]
    fn routes_need_the_token_and_a_real_id() {
        assert_eq!(
            parse_target(&format!("/{TOKEN}/img/{ID}/Primary?tag=abc&w=300"), TOKEN),
            Some(Route::Image { id: ID.into(), kind: "Primary", tag: "abc".into(), width: 320 })
        );
        assert_eq!(parse_target(&format!("/wrong/img/{ID}/Primary?tag=a"), TOKEN), None);
        assert_eq!(parse_target(&format!("/{TOKEN}/img/{ID}/Screenshot?tag=a"), TOKEN), None);
        assert_eq!(parse_target(&format!("/{TOKEN}/img/{ID}/Primary?tag=../x"), TOKEN), None);
        assert_eq!(parse_target(&format!("/{TOKEN}/img/../../etc/Primary?tag=a"), TOKEN), None);
    }

    #[test]
    fn server_paths_stay_under_one_video() {
        assert_eq!(
            parse_target(&format!("/{TOKEN}/jf/videos/{ID}/master.m3u8?a=1&ApiKey=s"), TOKEN),
            Some(Route::Server { path: format!("/videos/{ID}/master.m3u8?a=1"), cache: false })
        );
        assert_eq!(
            parse_target(&format!("/{TOKEN}/jf/Videos/{ID}/Trickplay/320/0.jpg?mediaSourceId=x"), TOKEN),
            Some(Route::Server { path: format!("/Videos/{ID}/Trickplay/320/0.jpg?mediaSourceId=x"), cache: true })
        );
        assert_eq!(parse_target(&format!("/{TOKEN}/jf/Videos/{ID}/../../Users"), TOKEN), None);
        assert_eq!(parse_target(&format!("/{TOKEN}/jf/Videos/{ID}/%2e%2e/x"), TOKEN), None);
        assert_eq!(parse_target(&format!("/{TOKEN}/jf/Users/{ID}/x"), TOKEN), None);
        assert_eq!(parse_target(&format!("/{TOKEN}/jf/Videos/{ID}"), TOKEN), None);
    }

    #[test]
    fn playlists_lose_the_token() {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmain.m3u8?DeviceId=a&ApiKey=secret\n";
        assert_eq!(clean_playlist(text), "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmain.m3u8?DeviceId=a\n");
    }

    #[test]
    fn sniffs_types() {
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), "image/jpeg");
        assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), "image/webp");
    }
}
