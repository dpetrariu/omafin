mod app;
mod config;
mod error;
mod jellyfin;
mod library;
mod media;
mod methods;
mod paths;
mod playback;
mod rpc;
mod secrets;

use std::process::ExitCode;

fn usage() -> ExitCode {
    eprintln!("usage: omafin <serve|version|check>");
    eprintln!("  serve    run the backend for the Omarchy plugin (JSON-RPC on stdio)");
    eprintln!("  version  print the version and API revision");
    eprintln!("  check    test the saved server and sign-in");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();
    match command.as_str() {
        "version" | "--version" | "-V" => {
            println!("omafin {} (api {})", env!("CARGO_PKG_VERSION"), methods::API_VERSION);
            ExitCode::SUCCESS
        }
        "serve" => run(serve()),
        "check" => run(check()),
        _ => usage(),
    }
}

fn run(future: impl std::future::Future<Output = ExitCode>) -> ExitCode {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .expect("tokio runtime");
    runtime.block_on(future)
}

async fn serve() -> ExitCode {
    let (notifier, out) = rpc::Notifier::channel();
    let app = match app::App::start(paths::Paths::from_env(), notifier).await {
        Ok(app) => app,
        Err(err) => {
            eprintln!("omafin: could not start: {err}");
            return ExitCode::FAILURE;
        }
    };
    tokio::select! {
        _ = rpc::serve(app.clone(), out) => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    // Tell the server playback ended, so it stops any transcode.
    let _ = tokio::time::timeout(std::time::Duration::from_secs(3), playback::stop_all(&app)).await;
    ExitCode::SUCCESS
}

async fn check() -> ExitCode {
    let paths = paths::Paths::from_env();
    let settings = config::Settings::load(&paths);
    let Some(token) = secrets::load(&paths).await else {
        eprintln!("Not signed in. Open Omafin and sign in to your Jellyfin server.");
        return ExitCode::FAILURE;
    };
    let client = jellyfin::Jellyfin::new(settings.device_id.clone());
    let mut ok = false;
    for url in [&settings.server_url, &settings.external_url] {
        if url.is_empty() {
            continue;
        }
        let Some(info) = client.public_info(url).await else {
            println!("{url}: no Jellyfin server answered");
            continue;
        };
        match client.unsaved(reqwest::Method::GET, &format!("{url}/Users/Me"), Some(&token), None).await {
            Ok(me) => {
                ok = true;
                println!(
                    "{url}: {} (Jellyfin {}) as {}",
                    info["ServerName"].as_str().unwrap_or("?"),
                    info["Version"].as_str().unwrap_or("?"),
                    me["Name"].as_str().unwrap_or("?")
                );
            }
            Err(err) => println!("{url}: {err}"),
        }
    }
    if ok { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
