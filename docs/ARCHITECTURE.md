# Omafin architecture

Omafin follows Omamail's and Omamich's split: QML owns presentation and interaction, a Rust process owns the network, the session token, the media proxy and mpv. They talk over newline-delimited JSON-RPC 2.0 on stdin/stdout.

## Shell entry points (`manifest.json`)

- `ui/Service.qml` — constructed by the shell at startup and kept for its life. Starts `bin/omafin serve`, holds settings, the account, the server and its libraries, builds image and media URLs, and hears `playback.changed` when mpv plays or stops.
- `ui/BarWidget.qml` — the bar icon. A dot while mpv plays something Omafin started; the urgent colour when the server cannot be reached.
- `ui/App.qml` — the window. Owns where you are (section, page stack, history), the key context, the player, and what every action does (open, play, mark watched, favourite, menus). Views draw and report.

## Backend (`src/`)

| Module | Owns |
| --- | --- |
| `rpc.rs` | Frame reading, concurrent dispatch, one writer for stdout, notifications (`server.changed`, `playback.changed`). |
| `methods.rs` | The method table. Unknown methods are refused. Settings, signing in (password, Quick Connect), signing out. |
| `library.rs` | Library requests (home rows, lists, details, seasons, episodes, search, marks), reshaped into cards so the UI never depends on Jellyfin's item format. Every id is validated before it reaches a URL; sorts, filters and item types come from fixed lists. |
| `playback.rs` | `PlaybackInfo` with a device profile, choosing direct play or the server's HLS transcode, the stream path through the proxy, subtitle URLs, media segments and trickplay, playback reports (start, progress at most every 10 s, pause, stop), and mpv: started with `--idle=once`, given the file over its JSON IPC socket (so no URL or token is on its command line), observed for position and pause, reported for. |
| `jellyfin/` | The HTTP client: home address first, away address as fallback, the `Authorization: MediaBrowser …` header, readable errors (401 → signed out). `profile.rs` is the device profile: both players decode with FFmpeg, so nearly everything plays directly; the window takes text subtitles as WebVTT and has picture subtitles burned in, mpv embeds everything. |
| `media.rs` | A 127.0.0.1 HTTP server that QML `Image`, `MediaPlayer` and mpv load from. Paths start with a random per-process token; the session token never reaches QML or a command line. Images are cached on disk by tag under a size cap (LRU pruning). `/jf/Videos/{id}/…` passes the file, HLS playlists and segments, subtitles and trickplay tiles through, with Range; playlists have Jellyfin's `ApiKey` taken out of every line, since the proxy adds the header itself. |
| `secrets.rs` | The access token in the Secret Service keyring (oo7); a 0600 file only when no keyring answers. |
| `config.rs`, `paths.rs` | `~/.config/omafin/config.json` (0600, written atomically), XDG directories, the device id. |

## Window (`ui/`)

- `components/BrowsePage.qml` — a header and rows of cards (`CardRow`): Home, details pages and search results are all this. j/k move between rows, h/l along them; a header can be a row of its own (the Play button, the home banner).
- `components/CardGrid.qml` — every grid: libraries, collections, favourites, genres, a person's films. Loads 120 at a time as you near the end.
- `components/MediaCard.qml` — a poster or landscape card; watched is a check, unwatched episodes a count, progress a bar, favourite a heart, the keyboard cursor a thick ring.
- `components/Player.qml` — the player: `MediaPlayer` on the proxy's stream, subtitles parsed from WebVTT and drawn as text, skip buttons from media segments, Up next with a countdown, trickplay previews, pickers that switch audio in place on a direct file and ask the server again for anything it converts.
- `keys/Keymap.js` + `components/KeyRouter.qml` — one table of every binding, by context (`browse`, `player`, `search`, `page`, `dialog`). Text-entry contexts bind no bare letters. The shortcut sheet and the status-bar hints are drawn from the same table.
- `lib/Format.js` — words and numbers (runtimes, "Ends at", episode codes, play labels), WebVTT parsing, segment and Up-next timing, trickplay frame lookup. Pure and tested.
- `components/Theme.qml` — every colour and size comes from the active Omarchy theme (`qs.Commons`), created once in App and passed down.

## Tests

- `cargo test` — config, ids, the auth header, card shaping, trickplay choice, subtitle and audio picking, track numbering, token stripping, proxy routes.
- `tests/backend_e2e.py` — the real backend against `tests/mock_jellyfin.py`: probing, password and Quick Connect sign-in, sign-out, home rows, lists with sorting and filters and their refusals, details, seasons, episodes, search, marks with undo, direct play, burned-in and bitrate transcodes, playlists without the token, the proxy's refusals, playback reports, and the mpv handoff with a fake mpv (`tests/fakebin/mpv`).
- `tests/ui_e2e.py` — the real window off-screen against the mock: Quick Connect in the sign-in page, home, keyboard marks with Undo, card menu, a show's page, a library grid, search, window playback (reports, subtitles, burn-in, skip intro, up next), mpv, settings, the narrow layout and the shortcut sheet.
- `tests/fetch_e2e.py` — a plugin without a backend downloads and verifies one.
- `tests/ui_logic.js` — Format, Items, the key table and wire parsing.
