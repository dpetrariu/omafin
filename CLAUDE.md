# Omafin — working agreements

Omafin is a Jellyfin client built as an Omarchy shell plugin, following the structure and interface principles of [Omamail](https://github.com/huacnlee/omamail) and Omamich, and the layout and flow of [Fladder](https://github.com/DonutWare/Fladder). Read `README.md` for what it does and `docs/ARCHITECTURE.md` for how the pieces fit before changing anything.

## Shape of the code

- `src/` — Rust backend, `omafin serve`, JSON-RPC 2.0 over stdin/stdout (one JSON object per line). `methods.rs` is the only method table; `library.rs` library calls and card shaping; `playback.rs` PlaybackInfo, reports and mpv; `media.rs` the token-guarded 127.0.0.1 media proxy; `jellyfin/` the HTTP client and the device profile.
- `ui/` — QML loaded by the Omarchy shell (Quickshell). `Service.qml` lives as long as the shell and owns the backend and shared state; `App.qml` is the window and owns navigation, key context, the player and every action; `views/` draw and report; `components/` are reusable; `lib/*.js` and `keys/Keymap.js` hold testable logic.
- `tests/` — `mock_jellyfin.py` (in-memory Jellyfin, `--seed` for a small library, `--media` for a real test video), `backend_e2e.py`, `ui_e2e.py` (the real window off-screen), `fetch_e2e.py`, `ui_logic.js`, `fakebin/mpv` (a stand-in mpv), and `tests/ui/shell.qml`, a stand-in shell for the UI tests.

## Rules that protect people's libraries

- **Never send a write to a real Jellyfin server while developing or testing.** Writes include watched and favourite marks, `UserData`, and every `/Sessions/Playing*` report — a report moves someone's resume point and can mark a film watched. Read-only `GET`s, searches and `POST /Items/{id}/PlaybackInfo` (it only negotiates) against a real server are fine for checking API shapes; fetching a transcode's playlist starts work on the server, so keep that to the mock too. Every change is tested against `tests/mock_jellyfin.py`.
- **Never play anything from a window or backend connected to a real server** in a test: the window reports playback as soon as it starts. Drive a real-server window only with `omarchy-shell shell call omafin navigate <id>`, which refuses play, marks and anything else that changes state.
- **Do not screenshot or drive the person's desktop while they are using it.** Prefer `tests/ui_e2e.py`, which renders off-screen.
- The session token never reaches QML, a URL QML sees, a playlist, or mpv's command line: the proxy adds the header and strips `ApiKey` from what the server hands back (`playback::strip_token`, `media::clean_playlist`). Keep the tests that assert this.
- Test processes get their own `OMAFIN_HOME` (config, data, cache, and no keyring). Never run `omafin serve` against the real config in a test.
- Keys that change the library never auto-repeat (`changes: true` in `Keymap.js`). Marks offer Undo; undoing "watched" restores the resume position.

## Development loop

```bash
make test                       # everything: Rust, backend end-to-end, UI end-to-end, release download, UI logic
make install                    # rebuild bin/omafin (the plugin runs this binary)
./install.sh                    # first time (and to update): build, link into Omarchy, enable, restart the shell
omarchy restart shell           # the shell caches QML; restart after UI edits
OMAFIN_UI_SHOTS=/tmp/shots python3 tests/ui_e2e.py target/debug/omafin   # keep screenshots
```

Rust comes from mise: prefix cargo with `mise exec rust@latest cmake@latest --` (or pass `CARGO=` to make). The tests need `ffmpeg` to make their one-minute test video.

- **Look at the screenshots** the UI test leaves in `$OMAFIN_UI_SHOTS`; passing assertions do not prove a view looks right. The off-screen platform does not draw video frames, so the player shows black there; check real playback by hand.
- After a UI run, read the harness log (`/tmp/omafin-ui-*/qs.log`) and fix anything mentioning `omafin` — `ui_e2e.py` fails on TypeError, ReferenceError, "Unable to assign", "Cannot assign" and binding loops.
- `qmllint -I /usr/lib/qt6/qml <file>` catches syntax errors before a slow UI run; unresolved `qs.*` imports are expected noise.
- The test hook `js` wraps its argument in `return (…)`: chain statements with commas, not semicolons.

## QML pitfalls met here

- `data` is every Item's default property: a view property named `data` swallows its children. HomeView's is `home`.
- A child binding `theme: theme` binds to itself; App's Theme has id `appTheme`.
- A `signal xChanged` clashes with property `x`'s change signal; two functions with one name do too.
- Name clashes with `QtQuick.Controls`: import it as `QQC`; our popup is `PopupMenu`, our modal is `Sheet`. Inline components avoid `Label`.
- A binding that can yield `undefined` for a bool leaves the property at its default: compare with `=== true`.
- An imperative assignment breaks a binding for good (BrowsePage's row cursor once stuck on row 0 that way); use an explicit "moved" flag instead of a binding you later assign.
- Read a binding into a local before acting on it: `seekTo(segment.end)` changes `segment` before the next line runs.
- Callbacks from `service.call` can arrive after a view is destroyed: every one starts with `if (!root) return`. Deferred work uses a child `Timer`, not `Qt.callLater(fn)`.
- Objects from a `.pragma library` file live in another JS context; compare them in Node tests as JSON.

## Design principles

- All colours and sizes come from the Omarchy theme through `components/Theme.qml`; secondary text mixes foreground toward background. Never convey state by colour alone (watched is a check, the cursor is a thick ring, the active tab has a bar).
- One key table (`keys/Keymap.js`) drives shortcuts, the status-bar hints and the `?` sheet. Text-entry contexts bind no bare letters.
- One grid for every list, one row of actions on every page, the same menu on every card (Fladder's three strongest ideas).
- Actions that open another surface end in `...`. Labels say their real scope ("Resume S1 · E3", "Remove from Continue watching").
- Untrusted text (server data) renders as `Text.PlainText`. Ids are validated before reaching a URL.

## Releases and the backend binary

- The plugin runs `bin/omafin` and requires its `omafin version` to equal `manifest.json`'s version. If it does not, `Service.qml` runs `scripts/fetch-backend.sh`, which downloads `omafin-<version>-linux-<arch>.tar.gz` from the `v<version>` release, checks it against `SHA256SUMS` and that the binary reports the version, then swaps it in. A checkout with `target/` is a development copy and is never overwritten.
- Cut a release with `scripts/release.sh X.Y.Z` from a clean, pushed `main`. `.github/workflows/release.yml` refuses a tag that disagrees with `Cargo.toml` or `manifest.json`, builds on `ubuntu-22.04` and `ubuntu-22.04-arm`, and publishes.

## How a feature is added

1. Backend method in `src/` with input validation, registered in `methods.rs`; unit tests for pure logic.
2. Mock support in `tests/mock_jellyfin.py` that mirrors Jellyfin's real behaviour (check the real shape with a read-only call first).
3. A check in `backend_e2e.py`, including refusals of bad input.
4. The UI, then a scenario in `ui_e2e.py` that drives it through `testHooks` and asserts on the mock's `/_state`.
5. `make test`, read the screenshots and the harness log, update `README.md`, commit with a message that says what changed and why.

For a wider change, get a fresh-eyes review from a separate agent focused on token leaks, unintended writes to the server and QML runtime errors.
