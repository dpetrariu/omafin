use std::sync::{Arc, RwLock};

use crate::config::Settings;
use crate::downloads::Downloads;
use crate::jellyfin::Jellyfin;
use crate::media::Media;
use crate::paths::Paths;
use crate::playback::Playback;
use crate::rpc::Notifier;

/// Everything a request handler can reach.
pub struct App {
    pub paths: Paths,
    pub settings: RwLock<Settings>,
    pub jellyfin: Arc<Jellyfin>,
    pub media: Arc<Media>,
    pub notifier: Notifier,
    pub playback: Arc<Playback>,
    pub downloads: Arc<Downloads>,
    pub token_storage: RwLock<&'static str>,
    /// A Quick Connect sign-in waiting for approval: the address and secret.
    pub quick_connect: tokio::sync::Mutex<Option<(String, String)>>,
}

impl App {
    pub async fn start(paths: Paths, notifier: Notifier) -> std::io::Result<Arc<App>> {
        paths.ensure()?;
        let settings = Settings::load(&paths);
        // The device id is made on first start; keep it, or every start
        // would look like a new device to the server.
        if !paths.config_file().exists() {
            let _ = settings.save(&paths);
        }
        let jellyfin = Arc::new(Jellyfin::new(settings.device_id.clone()));
        let token = if settings.signed_in() { crate::secrets::load(&paths).await } else { None };
        let token_storage = if token.is_some() { "keyring" } else { "" };
        jellyfin
            .configure(
                settings.server_enabled.then(|| settings.server_url.clone()),
                settings.external_enabled.then(|| settings.external_url.clone()),
                token,
                Some(settings.server_id.clone()),
            )
            .await;
        let media = Media::start(jellyfin.clone(), paths.media_cache()).await?;
        let downloads = Downloads::load(paths.downloads_index());
        let _ = media.downloads.set(downloads.clone());
        let app = Arc::new(App {
            paths,
            settings: RwLock::new(settings),
            jellyfin,
            media,
            notifier,
            playback: Playback::new(),
            downloads,
            token_storage: RwLock::new(token_storage),
            quick_connect: tokio::sync::Mutex::new(None),
        });
        crate::downloads::start(app.clone());
        // Keep the poster cache under its cap.
        let pruner = app.clone();
        tokio::spawn(async move {
            loop {
                let cap = pruner.settings.read().unwrap().cache_cap_mb * 1024 * 1024;
                let media = pruner.media.clone();
                let _ = tokio::task::spawn_blocking(move || media.prune(cap)).await;
                tokio::time::sleep(std::time::Duration::from_secs(900)).await;
            }
        });
        Ok(app)
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
    }

    /// Point the client at the saved addresses again.
    pub async fn reconnect(&self) {
        let settings = self.settings();
        self.jellyfin
            .set_urls(
                settings.server_enabled.then(|| settings.server_url.clone()),
                settings.external_enabled.then(|| settings.external_url.clone()),
            )
            .await;
        self.notifier.notify("server.changed", serde_json::json!({}));
    }
}
