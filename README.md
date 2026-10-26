# Omafin

Your [Jellyfin](https://jellyfin.org) films and shows in a native Omarchy window. Omafin follows the active Omarchy theme, is keyboard-first, and lives in the shell like [Omamail](https://github.com/huacnlee/omamail) and [Omamich](https://github.com/dpetrariu/omamich): a service that keeps running, a bar icon, and a window you summon. Its layout and flow follow [Fladder](https://github.com/DonutWare/Fladder), the Jellyfin client most often praised for a simple, good-looking UI.

## What it does

- **Home** opens on what you are watching: a banner for the film or episode in progress (h and l step through them), then **Continue watching**, **Next up**, and **Recently added** in each library. It refreshes every two minutes while open, and after you watch something.
- **Libraries** as they are on your server, each a grid you can sort (name, date added, release date, rating, runtime, last watched, random) and filter (not watched, in progress, watched, favourites, genre). The same grid serves collections, favourites, genres and a person's films.
- **Details pages**: the backdrop with the title's logo, year, rating, runtime and when it would end, genres, the story, and one row of actions — **Play** (or **Resume S1 · E3**, with how far you got drawn into the button), play from the start, watched, favourite, play in mpv, the trailer, more. Pick the audio and subtitle track before you start. A show plays the episode that comes next for you, and lists its episodes season by season, then seasons, cast and similar titles.
- **Search** across films, shows, episodes, collections and people.
- **The player**, in the window: keyboard-first (Space, J/L, arrows, F, M, Esc, as on most players), seeks that add up, **Skip intro / recap / credits** from Jellyfin's media segments (or skip them on their own), **Up next** with a countdown as the credits start, chapter marks and trickplay thumbnails on the timeline, audio, subtitle, quality and speed pickers, and an "Ends at" clock. Text subtitles are drawn by the window. Every video plays from its original file: Omafin never asks the server to transcode unless you allow it (Settings → Playback → "Let the server convert videos"), so a modest server is never loaded down. Picture subtitles (PGS, DVD), which the window cannot draw, then open in mpv. With converting allowed, the server can burn them in instead, lower the quality to fit a slow link, or fix a file the window cannot play.
- **mpv** in one key (m on any title, Shift+M while playing): for 4K HDR, Dolby Vision, TrueHD and picture subtitles straight from the file. Omafin drives mpv over its control socket and reports progress for it, so resume points and watched marks still reach Jellyfin. Settings can make mpv the player for everything.
- **Downloads**: the ⬇ button beside Play (or `Shift+D`) downloads the original file into `~/Videos/Omafin` (Movies/ and Shows/Series/Season NN/), with its pictures, cast, text subtitles and details saved beside it in `.omafin` folders. The button fills as a ring with the percentage, the status bar shows speed and time left, and it turns into a bin when done; deleting asks first and moves the files to the desktop trash. A show's page offers *Download Season N*. Downloads survive everything: a dropped connection, sleep, closing the window or restarting resume where they stopped; a file changed on the server is fetched again; space is checked before starting; a file deleted in the file manager is noticed. Nothing is ever transcoded for a download.
- **Watched, favourite and Continue watching** marks from any card (w, f, or the menu), each with Undo — undoing "watched" puts back where you were.
- **Your place everywhere**: playback is reported to Jellyfin as you watch, so you can stop here and resume on the TV.
- **Back and Forward** through the pages you visited (Alt+Left/Right, mouse buttons), a phone-width layout with tabs at the bottom, and a focus mode (F11) for the player.

## Install

You need [Omarchy](https://omarchy.org) 4 or later and a Jellyfin server (10.9 or newer; tested against 12.2). mpv is optional (`sudo pacman -S mpv`).

```bash
curl -fsSL https://raw.githubusercontent.com/dpetrariu/omafin/main/install.sh | bash
```

It downloads Omafin into `~/.local/share/omafin-plugin`, fetches the prebuilt backend for your machine (checked against the release checksums), or builds it if none fits, adds the plugin to Omarchy with its bar icon, and restarts the shell. `--build` always builds from source. From a checkout, run `./install.sh` instead.

### First start

Click the film icon in the bar and enter your Jellyfin address (for example `http://192.168.1.10:8096`). If the server has **Quick Connect** on, Omafin shows a six-digit code: in Jellyfin on your phone or in a browser, open your profile → **Quick Connect** and enter it. Otherwise, sign in with your user name and password. The session is kept in your keyring; your password is not stored.

To open Omafin from the keyboard, add a binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + J", "Omafin", "omarchy shell shell toggle omafin '{}'")
```

### Update and uninstall

Run the installer again to update. To remove it:

```bash
~/.local/share/omafin-plugin/scripts/uninstall.sh          # keeps your settings
~/.local/share/omafin-plugin/scripts/uninstall.sh --purge  # also removes settings, cache and the saved session
```

Nothing on the server is touched either way.

## Keys

Press `?` in the window for the full sheet. Browsing: `h j k l` move, `enter` open, `p` play, `Shift+P` from the start, `m` play in mpv, `w` watched, `f` favourite, `.` more, `/` or `Ctrl+K` search, `Alt+1…0` sidebar sections, `Ctrl+,` settings. Playing: `Space`/`k` pause, `←`/`j` back 10 s, `→`/`l` forward 30 s, `↑ ↓` volume, `m` mute, `s` skip intro or credits, `t` subtitles, `a` audio, `Shift+N` next episode, `PgUp`/`PgDn` chapters, `f` full window, `Shift+M` continue in mpv, `Esc` close.

Scripts and keybindings can move around (never mark, play or change anything) over IPC: `omarchy-shell shell call omafin navigate next`, `… navigate go:Movies`, `… navigate search:dune`.

## Development

```bash
make test        # Rust unit tests, the backend against a mock Jellyfin, the window off-screen, the release download, UI logic
make install     # rebuild bin/omafin
./install.sh     # link this checkout into Omarchy (first time), then: omarchy restart shell after UI edits
```

See `CLAUDE.md` for the working agreements and `docs/ARCHITECTURE.md` for how the pieces fit.

Licence: GPL-3.0-or-later.
