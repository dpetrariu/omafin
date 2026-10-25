//! The RPC surface. Each method name maps to one handler; anything else is
//! refused, so the UI cannot reach the network except through these.

use std::sync::Arc;

use reqwest::Method;
use serde_json::{Value, json};

use crate::app::App;
use crate::config::normalize_url;
use crate::error::{self, Error, METHOD_NOT_FOUND, Result};
use crate::jellyfin::profile::Player;
use crate::library::{self as lib, str_param};
use crate::{playback, secrets};

/// Bumped whenever a method, parameter or response changes shape.
pub const API_VERSION: u64 = 1;

pub async fn dispatch(app: &Arc<App>, method: &str, params: &Value) -> Result<Value> {
    match method {
        "system.info" => system_info(app).await,

        "settings.get" => settings_get(app).await,
        "settings.update" => settings_update(app, params).await,
        "auth.probe" => auth_probe(app, params).await,
        "auth.signIn" => auth_sign_in(app, params).await,
        "auth.quickConnectStart" => quick_connect_start(app, params).await,
        "auth.quickConnectPoll" => quick_connect_poll(app).await,
        "auth.quickConnectCancel" => {
            *app.quick_connect.lock().await = None;
            Ok(json!(true))
        }
        "auth.signOut" => auth_sign_out(app).await,
        "auth.test" => auth_test(app, params).await,

        "server.overview" => lib::server_overview(app).await,
        "views.list" => lib::views_list(app).await,
        "home" => lib::home(app).await,
        "items.list" => lib::items_list(app, params).await,
        "genres.list" => lib::genres_list(app, params).await,
        "item.get" => lib::item_get(app, params).await,
        "item.similar" => lib::similar(app, params).await,
        "item.setPlayed" => lib::set_played(app, params).await,
        "item.setFavorite" => lib::set_favorite(app, params).await,
        "item.clearResume" => lib::clear_resume(app, params).await,
        "show.seasons" => lib::seasons(app, params).await,
        "show.episodes" => lib::episodes(app, params).await,
        "show.nextEpisode" => lib::next_episode(app, params).await,
        "search" => lib::search(app, params).await,

        "play.prepare" => playback::prepare(app, params, Player::Window).await,
        "play.report" => playback::report(app, params).await,
        "play.mpv" => playback::play_in_mpv(app, params).await,
        "play.status" => Ok(playback::status(app).await),
        "play.stop" => {
            playback::stop_all(app).await;
            Ok(json!(true))
        }

        "cache.info" => cache_info(app).await,
        "cache.clear" => cache_clear(app).await,

        _ => Err(Error::new(METHOD_NOT_FOUND, format!("Unknown method: {method}"))),
    }
}

async fn system_info(app: &App) -> Result<Value> {
    Ok(json!({
        "name": "omafin",
        "version": env!("CARGO_PKG_VERSION"),
        "apiVersion": API_VERSION,
        "mediaBase": app.media.base_url(),
        "configured": app.jellyfin.is_configured().await,
        "hasToken": app.jellyfin.has_token().await,
        "mpv": playback::mpv_available(),
    }))
}

async fn settings_get(app: &App) -> Result<Value> {
    Ok(json!({
        "settings": app.settings().to_json(),
        "signedIn": app.jellyfin.has_token().await && app.settings().signed_in(),
        "tokenStorage": *app.token_storage.read().unwrap(),
        "mpv": playback::mpv_available(),
    }))
}

async fn settings_update(app: &App, params: &Value) -> Result<Value> {
    let patch = params.get("patch").cloned().unwrap_or(Value::Null);
    let (before, after) = {
        let mut settings = app.settings.write().unwrap();
        let before = settings.clone();
        settings.apply_patch(&patch)?;
        (before, settings.clone())
    };
    after.save(&app.paths)?;
    if before.server_url != after.server_url
        || before.external_url != after.external_url
        || before.server_enabled != after.server_enabled
        || before.external_enabled != after.external_enabled
    {
        app.reconnect().await;
    }
    settings_get(app).await
}

fn typed_url(params: &Value) -> Result<String> {
    let url = normalize_url(str_param(params, "url"))?;
    if url.is_empty() {
        return Err(Error::invalid("Enter the server address first"));
    }
    Ok(url)
}

/// What answers at an address: the server's name and version, whether Quick
/// Connect is on, and the users who show themselves on the sign-in screen.
async fn auth_probe(app: &App, params: &Value) -> Result<Value> {
    let url = typed_url(params)?;
    let Some(info) = app.jellyfin.public_info(&url).await else {
        return Err(Error::new(error::NETWORK, "No Jellyfin server answered at that address"));
    };
    let quick = app
        .jellyfin
        .unsaved(Method::GET, &format!("{url}/QuickConnect/Enabled"), None, None)
        .await
        .ok()
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let users: Vec<Value> = app
        .jellyfin
        .unsaved(Method::GET, &format!("{url}/Users/Public"), None, None)
        .await
        .ok()
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|u| u.get("Name").and_then(|n| n.as_str()).map(|n| json!(n)))
        .take(20)
        .collect();
    Ok(json!({
        "url": url,
        "name": info.get("ServerName").cloned().unwrap_or(Value::Null),
        "version": info.get("Version").cloned().unwrap_or(Value::Null),
        "quickConnect": quick,
        "users": users,
    }))
}

/// Keep what a successful sign-in returned: the token in the keyring, the
/// account and server in the settings.
async fn finish_sign_in(app: &App, url: &str, auth: &Value) -> Result<Value> {
    let token = auth.get("AccessToken").and_then(|v| v.as_str()).map(secrets::clean_token).unwrap_or_default();
    if !secrets::valid_token_shape(&token) {
        return Err(Error::new(error::SERVER, "Jellyfin did not hand over a session"));
    }
    let user_id = auth.pointer("/User/Id").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if !crate::jellyfin::valid_id(&user_id) {
        return Err(Error::new(error::SERVER, "Jellyfin did not say who signed in"));
    }
    let storage = secrets::store(&app.paths, &token).await?;
    *app.token_storage.write().unwrap() = storage.as_str();
    let info = app.jellyfin.public_info(url).await.unwrap_or(Value::Null);
    {
        let mut settings = app.settings.write().unwrap();
        // A sign-in at the away address keeps the home one, and the reverse.
        if settings.external_url != url {
            settings.server_url = url.to_string();
            settings.server_enabled = true;
        }
        settings.user_id = user_id;
        settings.user_name = auth.pointer("/User/Name").and_then(|v| v.as_str()).unwrap_or("").to_string();
        settings.server_id = info.get("Id").and_then(|v| v.as_str()).unwrap_or("").to_string();
        settings.server_name = info.get("ServerName").and_then(|v| v.as_str()).unwrap_or("").to_string();
        settings.save(&app.paths)?;
    }
    let settings = app.settings();
    app.jellyfin
        .configure(
            settings.server_enabled.then(|| settings.server_url.clone()),
            settings.external_enabled.then(|| settings.external_url.clone()),
            Some(token),
        )
        .await;
    app.notifier.notify("server.changed", json!({}));
    settings_get(app).await
}

async fn auth_sign_in(app: &App, params: &Value) -> Result<Value> {
    let url = typed_url(params)?;
    let username = str_param(params, "username").trim();
    if username.is_empty() {
        return Err(Error::invalid("Enter your Jellyfin user name"));
    }
    let password = str_param(params, "password");
    let auth = app
        .jellyfin
        .unsaved(Method::POST, &format!("{url}/Users/AuthenticateByName"), None, Some(json!({ "Username": username, "Pw": password })))
        .await
        .map_err(|e| match e.code {
            // A wrong password answers 401, which elsewhere means "signed out".
            error::UNAUTHORIZED => Error::new(error::UNAUTHORIZED, "That user name and password did not work"),
            _ => e,
        })?;
    finish_sign_in(app, &url, &auth).await
}

async fn quick_connect_start(app: &App, params: &Value) -> Result<Value> {
    let url = typed_url(params)?;
    let started = app
        .jellyfin
        .unsaved(Method::POST, &format!("{url}/QuickConnect/Initiate"), None, None)
        .await
        .map_err(|e| match e.code {
            error::UNAUTHORIZED | error::FORBIDDEN => Error::new(e.code, "Quick Connect is turned off on this server"),
            _ => e,
        })?;
    let secret = started.get("Secret").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let code = started.get("Code").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if secret.is_empty() || !secret.chars().all(|c| c.is_ascii_alphanumeric()) || code.is_empty() {
        return Err(Error::new(error::SERVER, "Jellyfin did not start Quick Connect"));
    }
    *app.quick_connect.lock().await = Some((url, secret));
    Ok(json!({ "code": code }))
}

async fn quick_connect_poll(app: &App) -> Result<Value> {
    let Some((url, secret)) = app.quick_connect.lock().await.clone() else {
        return Err(Error::invalid("Start Quick Connect first"));
    };
    let state = app
        .jellyfin
        .unsaved(Method::GET, &format!("{url}/QuickConnect/Connect?secret={secret}"), None, None)
        .await
        .map_err(|e| match e.code {
            error::NOT_FOUND => Error::new(e.code, "That Quick Connect code expired; start again"),
            _ => e,
        })?;
    if state.get("Authenticated").and_then(|v| v.as_bool()) != Some(true) {
        return Ok(json!({ "state": "waiting" }));
    }
    let auth = app
        .jellyfin
        .unsaved(Method::POST, &format!("{url}/Users/AuthenticateWithQuickConnect"), None, Some(json!({ "Secret": secret })))
        .await?;
    *app.quick_connect.lock().await = None;
    let settings = finish_sign_in(app, &url, &auth).await?;
    Ok(json!({ "state": "signedIn", "settings": settings }))
}

async fn auth_sign_out(app: &App) -> Result<Value> {
    playback::stop_all(app).await;
    // Ending the session on the server too removes this device from its list.
    let _ = app.jellyfin.post("/Sessions/Logout", Value::Null).await;
    secrets::delete(&app.paths).await;
    *app.token_storage.write().unwrap() = "";
    app.jellyfin.set_token(None).await;
    {
        let mut settings = app.settings.write().unwrap();
        settings.user_id.clear();
        settings.user_name.clear();
        settings.save(&app.paths)?;
    }
    app.notifier.notify("server.changed", json!({}));
    settings_get(app).await
}

/// Try the home and away addresses — typed or saved — and say which answer,
/// without saving anything.
async fn auth_test(app: &App, params: &Value) -> Result<Value> {
    let settings = app.settings();
    let mut results = serde_json::Map::new();
    for (field, saved, label) in [("serverUrl", &settings.server_url, "lan"), ("externalUrl", &settings.external_url, "wan")] {
        let url = match params.get(field).and_then(|v| v.as_str()) {
            Some(typed) => normalize_url(typed)?,
            None => saved.clone(),
        };
        if url.is_empty() {
            continue;
        }
        let outcome = match app.jellyfin.public_info(&url).await {
            Some(info) if settings.server_id.is_empty() || info["Id"].as_str() == Some(settings.server_id.as_str()) => {
                json!({ "ok": true, "url": url, "name": info["ServerName"], "version": info["Version"] })
            }
            Some(info) => json!({ "ok": false, "url": url, "error": format!("{} is a different Jellyfin server", info["ServerName"].as_str().unwrap_or("That")) }),
            None => json!({ "ok": false, "url": url, "error": "No Jellyfin server answered at that address" }),
        };
        results.insert(label.to_string(), outcome);
    }
    if results.is_empty() {
        return Err(Error::invalid("Enter the server address first"));
    }
    Ok(Value::Object(results))
}

async fn cache_info(app: &App) -> Result<Value> {
    let media = app.media.clone();
    let bytes = tokio::task::spawn_blocking(move || media.cache_size()).await.unwrap_or(0);
    Ok(json!({ "bytes": bytes, "capMb": app.settings().cache_cap_mb }))
}

async fn cache_clear(app: &App) -> Result<Value> {
    let media = app.media.clone();
    let freed = tokio::task::spawn_blocking(move || media.clear()).await.unwrap_or(0);
    Ok(json!({ "freed": freed }))
}
