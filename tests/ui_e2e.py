#!/usr/bin/env python3
"""Drive the real Omafin window off-screen against the seeded mock Jellyfin.

Quickshell runs with QT_QPA_PLATFORM=offscreen and tests/ui/shell.qml as its
shell, so nothing appears on the desktop and no real server is involved.
Screenshots of each step land in $OMAFIN_UI_SHOTS (or a temp folder).

usage: ui_e2e.py path/to/omafin
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from backend_e2e import (ARRIVAL, BLADE, HOMELAND, MOVIES, S1E2, approve, free_port,  # noqa: E402
                         make_media, start_mock, state, wait_for)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SHELL = "/usr/share/omarchy/shell"
S1E3 = "a00000000000000000000000000000d5"


class Harness:
    def __init__(self, binary, root, shots):
        self.root = root
        self.shots = shots
        qs_dir = os.path.join(root, "qs")
        os.makedirs(qs_dir)
        for name in ("Commons", "Ui"):
            os.symlink(os.path.join(SHELL, name), os.path.join(qs_dir, name))
        shutil.copy(os.path.join(HERE, "ui", "shell.qml"), qs_dir)
        self.shell = os.path.join(qs_dir, "shell.qml")
        home = os.path.join(root, "home")
        os.makedirs(os.path.join(home, "config"))
        self.env = dict(os.environ, QT_QPA_PLATFORM="offscreen", WAYLAND_DISPLAY="",
                        OMAFIN_UI=os.path.join(REPO, "ui"), OMAFIN_BIN=binary, OMAFIN_HOME=home,
                        # The desktop trash too: removing a download must never reach the real one.
                        XDG_DATA_HOME=os.path.join(root, "xdg"),
                        PATH=os.path.join(HERE, "fakebin") + os.pathsep + os.environ["PATH"])
        self.log = open(os.path.join(root, "qs.log"), "w")
        self.proc = subprocess.Popen(["qs", "-p", self.shell], env=self.env, stdout=self.log, stderr=subprocess.STDOUT)

    def ipc(self, *args):
        out = subprocess.run(["qs", "-p", self.shell, "ipc", "call", "test", *args], env=self.env,
                             capture_output=True, text=True, timeout=30)
        return out.stdout.strip()

    def js(self, code):
        result = self.ipc("js", code)
        if result.startswith("error:"):
            raise AssertionError(f"{code} -> {result}")
        return result

    def value(self, code):
        return json.loads(self.js(f"JSON.stringify({code})"))

    def nav(self, action, settle=0.5):
        assert self.ipc("nav", action) == "ok", action
        time.sleep(settle)

    def key(self, action, settle=0.5):
        self.ipc("key", action)
        time.sleep(settle)

    def shot(self, name):
        path = os.path.join(self.shots, name + ".png")
        self.ipc("shot", path)
        time.sleep(0.8)
        return path

    def errors(self):
        self.log.flush()
        with open(os.path.join(self.root, "qs.log")) as f:
            return [line for line in f if "omafin" in line and ("TypeError" in line or "ReferenceError" in line
                    or "unavailable" in line or "Error:" in line or "is not a type" in line or "Unable to assign" in line
                    or "Cannot assign" in line or "Binding loop" in line)]

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def reports(port, item=None):
    return [r for r in state(port)["reports"] if item is None or r["item"] == item]


def main():
    binary = os.path.abspath(sys.argv[1])
    port = free_port()
    root = tempfile.mkdtemp(prefix="omafin-ui-")
    media = make_media(os.path.join(root, "media"))
    mock = start_mock(port, media, big=True)
    shots = os.environ.get("OMAFIN_UI_SHOTS") or os.path.join(root, "shots")
    os.makedirs(shots, exist_ok=True)
    h = None
    try:
        h = Harness(binary, root, shots)
        wait_for("the window is up", lambda: h.ipc("ready") == "yes", 30)
        wait_for("the sign-in page", lambda: h.value("!!hooks.setup.item"), 10)
        time.sleep(0.5)
        h.shot("01-setup")

        # Sign in with Quick Connect, as a person would: address, Continue,
        # then the code is approved on "another device" (the mock).
        h.js(f"hooks.setup.item.address = '127.0.0.1:{port}'")
        h.js("hooks.setup.item.probe()")
        wait_for("a Quick Connect code", lambda: len(h.value("hooks.setup.item.code")) == 6, 10)
        h.shot("02-quick-connect")
        approve(port, h.value("hooks.setup.item.code"))
        wait_for("signed in", lambda: h.value("service.configured") is True, 10)
        wait_for("the home rows", lambda: h.value("app.view() && app.view().home ? app.view().home.resume.length : 0") == 1, 15)
        time.sleep(1.5)
        h.shot("03-home")
        assert h.value("app.sections.map(function(s) { return s.label })") == ["Home", "Movies", "TV Shows", "Collections", "Archive", "Favourites"]
        assert h.value("app.view().home.nextUp[0].id") == S1E2
        offsets = h.value("[0, 1, 2, 3].map(function(i) { var r = app.view().browse.rowItem(i); return r ? r.scrolledBy : 0 })")
        assert all(abs(o) < 0.5 for o in offsets), ("a home row starts scrolled in", offsets)
        print("ok: Quick Connect sign-in and home")

        # One wheel notch glides the page a good step, even over a row of
        # cards; Home refreshing keeps the place.
        page = "app.view().browse"
        y0 = h.value(page + ".flickable.contentY")
        row_y = h.value(page + ".rowItem(1).mapToItem(" + page + ", 0, 40).y")
        h.js(f"{page}.wheel.handle(0, -120, 0, 0, false, {row_y}, 0)")
        time.sleep(1.6)
        y1 = h.value(page + ".flickable.contentY")
        bottom = h.value(page + ".flickable.contentHeight - " + page + ".flickable.height")
        notch = h.value(page + ".wheel.notch")
        assert notch >= 300 and abs(y1 - min(y0 + notch, bottom)) < notch * 0.03 + 2, (y0, y1, notch, bottom)
        assert h.value(page + ".wheel.active") is False, "the glide did not settle"
        h.js("app.view().reload()")
        wait_for("home reloaded", lambda: h.value("app.view().loading") is False, 10)
        time.sleep(0.5)
        assert abs(h.value(page + ".flickable.contentY") - y1) < 2, "home jumped after a refresh"
        h.js(f"{page}.wheel.handle(0, 120, 0, 0, false, {row_y}, 0)")
        time.sleep(1.6)
        assert abs(h.value(page + ".flickable.contentY") - y0) < notch * 0.03 + 2
        print("ok: wheel scrolling")

        # The keyboard: down to Continue watching, w marks it watched, Undo.
        h.nav("down")
        target = h.value("app.view().currentTarget()")
        assert target and target["id"] == ARRIVAL, (target, h.value("app.keyContext"))
        h.key("watched", 1.0)
        wait_for("watched on the server", lambda: ARRIVAL in state(port)["played"], 5)
        assert "Marked Arrival as watched" in h.value("hooks.toast.message")
        h.shot("04-watched-toast")
        h.js("hooks.toast.action()")
        wait_for("unwatched again", lambda: ARRIVAL not in state(port)["played"], 5)
        wait_for("back where it was", lambda: state(port)["positions"].get(ARRIVAL) == 4, 5)
        # Undo refreshes Home; let it land before the next marks.
        time.sleep(0.5)
        wait_for("home refreshed", lambda: h.value("app.view().loading") is False, 10)
        time.sleep(0.3)
        h.key("favorite", 1.0)
        wait_for("a favourite", lambda: ARRIVAL in state(port)["favorites"], 5)
        h.key("favorite", 1.0)
        wait_for("not a favourite", lambda: ARRIVAL not in state(port)["favorites"], 5)
        target = h.value("app.view().currentTarget()")
        assert target and target["id"] == ARRIVAL, "the cursor left the marked card"
        # On a longer row too: the cursor stays on the card that was marked.
        h.nav("down")
        h.nav("down")
        h.nav("right")
        h.nav("right")
        marked = h.value("app.view().currentTarget().id")
        h.key("favorite", 1.0)
        wait_for("that one is a favourite", lambda: marked in state(port)["favorites"], 5)
        assert h.value("app.view().currentTarget().id") == marked
        h.key("favorite", 1.0)
        wait_for("and not again", lambda: marked not in state(port)["favorites"], 5)
        assert h.value("app.view().currentTarget().id") == marked
        h.nav("first")
        h.nav("up")
        h.nav("up")
        print("ok: watched and favourite from the keyboard, with Undo, cursor kept")

        # The menu on a card offers the actions, by name.
        h.key("menu", 0.6)
        labels = h.value("hooks.menu.items.map(function(i) { return i.label })")
        assert labels[:2] == ["Resume", "Play from the start"] and "Mark as watched" in labels and "Remove from Continue watching" in labels, labels
        h.shot("05-card-menu")
        h.nav("back")
        # A menu is as wide as its longest row (audio track names run long).
        long = "Surround 7.1 - English - Dolby TrueHD + Dolby Atmos - Default"
        h.js(f"app.showMenu([{{ id: 'a', label: '{long}', icon: 'check' }}, {{ id: 'b', label: 'Off' }}], hooks.content, function() {{}}, 10, 10)")
        time.sleep(0.6)
        w = h.value("hooks.menu.width")
        assert w >= h.value("hooks.menu.widest") and w > 400, (w, h.value("hooks.menu.widest"))
        h.nav("back")
        h.js("app.showMenu([], hooks.content, function() {}, 10, 10)")
        time.sleep(0.4)
        assert h.value("hooks.menu.visible") is False, "an empty menu opened"
        print("ok: card menu")

        # A show's page: Play goes to the next episode, episodes and seasons are rows.
        h.js(f"app.openItem({{ id: '{HOMELAND}', type: 'Series', name: 'Homeland' }})")
        wait_for("the show page", lambda: h.value("app.view().episodes.length") == 3, 10)
        assert h.value("app.view().playTarget.id") == S1E2
        assert h.value("app.view().rows.map(function(r) { return r.key.split(':')[0] })") == ["episodes", "seasons", "people", "similar"]
        time.sleep(1.2)
        h.shot("06-show")
        # Season 2 from the seasons row.
        h.nav("down")
        h.nav("down")
        h.nav("right")
        h.nav("open", 1.5)
        assert h.value("app.view().currentSeason.name") == "Season 2"
        print("ok: show page and seasons")

        # A library grid, its sort, and paging.
        h.nav("go:Movies", 2)
        wait_for("the films", lambda: h.value("app.view().items.length") == 6, 10)
        assert h.value("app.view().items[0].name") == "Arrival"
        h.js("(app.view().sort = 'added', app.view().descending = true, app.view().reload(true))")
        wait_for("newest first", lambda: h.value("app.view().items[0].name") == "Fargo", 5)
        h.js("(app.view().sort = 'name', app.view().descending = false, app.view().show = 'favorite', app.view().reload())")
        wait_for("favourites only", lambda: h.value("app.view().items.map(function(i) { return i.name })") == ["Casablanca"], 5)
        h.js("(app.view().show = 'all', app.view().reload())")
        wait_for("everything again", lambda: h.value("app.view().items.length") == 6, 5)
        time.sleep(1)
        h.shot("07-movies")
        print("ok: library grid, sorting and filters")

        # A genre grid reached from a page offers every genre to switch to.
        h.js("app.push({ kind: 'grid', title: 'Drama', genres: ['Drama'], types: 'Movie', recursive: true, sort: 'name' })")
        wait_for("genre choices", lambda: "Science Fiction" in h.value("app.view().genreChoices"), 10)
        assert h.value("app.view().items.map(function(i) { return i.name })") == ["Arrival", "Casablanca", "Fargo"]

        # A long grid keeps its place when the next page loads, when a film
        # is marked and when it reloads; a new sort starts at the top.
        h.nav("go:Archive", 2)
        wait_for("the first page", lambda: h.value("app.view().items.length") == 120, 10)
        grid = "app.view().children.filter(function(c) { return c.cellWidth !== undefined })[0]"
        h.js(f"{grid}.handleKey('pageDown'), {grid}.handleKey('pageDown'), {grid}.handleKey('pageDown')")
        time.sleep(0.5)
        gv = grid + ".children.filter(function(c) { return c.contentY !== undefined })[0]"
        y = h.value(gv + ".contentY")
        assert y > 500, y
        h.js("app.view().loadMore()")
        wait_for("the second page", lambda: h.value("app.view().items.length") == 240, 10)
        time.sleep(0.4)
        assert abs(h.value(gv + ".contentY") - y) < 2, "the grid jumped after loading more"
        h.js("app.view().patch(app.view().items[3].id, { favorite: true })")
        time.sleep(0.4)
        assert abs(h.value(gv + ".contentY") - y) < 2, "the grid jumped after a mark"
        h.js("app.view().reload()")
        wait_for("reloaded at its size", lambda: h.value("app.view().loading") is False, 10)
        time.sleep(0.4)
        assert h.value("app.view().items.length") == 240 and abs(h.value(gv + ".contentY") - y) < 2, "the grid jumped after a reload"
        h.js("(app.view().sort = 'added', app.view().descending = true, app.view().reload(true))")
        wait_for("a new sort", lambda: h.value("app.view().items.length") == 120, 10)
        time.sleep(0.4)
        assert h.value(gv + ".contentY") <= 1, "a new sort did not start at the top"
        h.js("(app.view().sort = 'name', app.view().descending = false, app.view().remember())")
        print("ok: long grids keep their place")

        # A touchpad flick: the grid follows the fingers, then coasts on and
        # slows to a stop. Fingers that pause before lifting do not coast.
        w = grid + ".wheel"
        start = h.value(gv + ".contentY")
        h.js(f"({w}.handle(0, 0, 0, 0, false, 100, 1, 1000), " + ", ".join(f"{w}.handle(0, 0, 0, -60, false, 100, 2, {1000 + 16 * (i + 1)})" for i in range(6)) + f", {w}.handle(0, 0, 0, 0, false, 100, 3, 1100))")
        followed = 6 * 60 * h.value(w + ".fingerGain")
        time.sleep(2.0)
        coasted = h.value(gv + ".contentY") - start
        assert coasted > followed + 800, (coasted, followed)
        assert h.value(w + ".active") is False, "the glide never stopped"
        start = h.value(gv + ".contentY")
        h.js(f"({w}.handle(0, 0, 0, 0, false, 100, 1, 5000), " + ", ".join(f"{w}.handle(0, 0, 0, -60, false, 100, 2, {5000 + 16 * (i + 1)})" for i in range(6)) + f", {w}.handle(0, 0, 0, 0, false, 100, 3, 5400))")
        time.sleep(1.0)
        assert abs(h.value(gv + ".contentY") - start - followed) < 2, "a paused release coasted"
        # A glide into the end of what is loaded keeps going while the next
        # page arrives.
        h.js("app.view().reload(true)")
        wait_for("first page again", lambda: h.value("app.view().items.length") == 120, 10)
        time.sleep(0.5)
        h.js(f"{w}.scrollBy({gv}.contentHeight - {gv}.height - 2500)")
        time.sleep(0.3)
        assert h.value("app.view().items.length") == 120
        h.js(f"({w}.handle(0, 0, 0, 0, false, 100, 1, 20000), " + ", ".join(f"{w}.handle(0, 0, 0, -110, false, 100, 2, {20000 + 16 * (i + 1)})" for i in range(6)) + f", {w}.handle(0, 0, 0, 0, false, 100, 3, 20100))")
        wait_for("the next page while gliding", lambda: h.value("app.view().items.length") == 240, 5)
        time.sleep(0.15)
        assert h.value(w + ".coasting") is True, "loading the next page stopped the glide"
        time.sleep(2.0)
        # The ends stretch like a rubber band: a fast flick into the top
        # carries a little past it and springs back; pulling past it with the
        # fingers meets resistance and springs back on release.
        h.js(f"{w}.scrollBy(-1000000)")
        time.sleep(0.3)
        top = h.value(gv + ".originY - " + gv + ".topMargin")
        h.js(f"{w}.scrollBy(2000)")
        time.sleep(0.3)
        h.js(f"({w}.handle(0, 0, 0, 0, false, 100, 1, 30000), " + ", ".join(f"{w}.handle(0, 0, 0, 110, false, 100, 2, {30000 + 16 * (i + 1)})" for i in range(6)) + f", {w}.handle(0, 0, 0, 0, false, 100, 3, 30100))")
        time.sleep(2.0)
        peak = h.value(w + ".peakStretch")
        assert 20 < peak < 160, peak
        assert abs(h.value(gv + ".contentY") - top) < 0.5 and h.value(w + ".active") is False, "the bounce did not settle on the top"
        h.js(f"({w}.handle(0, 0, 0, 0, false, 100, 1, 40000), " + ", ".join(f"{w}.handle(0, 0, 0, 80, false, 100, 2, {40000 + 50 * (i + 1)})" for i in range(5)) + ")")
        time.sleep(0.3)
        pulled = top - h.value(gv + ".contentY")
        assert 20 < pulled < 5 * 80 * 1.25 * 0.6, pulled
        h.js(f"{w}.handle(0, 0, 0, 0, false, 100, 3, 40400)")
        time.sleep(1.2)
        assert abs(h.value(gv + ".contentY") - top) < 0.5 and h.value(w + ".active") is False, "the pull did not spring back"
        print("ok: rubber-band ends")

        # A key press catches a glide.
        h.js(f"({w}.handle(0, 0, 0, 0, false, 100, 1, 9000), " + ", ".join(f"{w}.handle(0, 0, 0, -80, false, 100, 2, {9000 + 16 * (i + 1)})" for i in range(6)) + f", {w}.handle(0, 0, 0, 0, false, 100, 3, 9100))")
        time.sleep(0.1)
        h.nav("down")
        assert h.value(w + ".active") is False, "a key did not stop the glide"
        print("ok: touchpad momentum")

        # Search.
        h.nav("search:blade", 2)
        wait_for("search results", lambda: h.value("app.view().result ? app.view().result.movies.length : 0") == 1, 10)
        h.shot("08-search")
        print("ok: search")

        # Closing while a play is still being prepared: nothing plays, nothing is reported.
        casablanca = "a0000000000000000000000000000066"
        h.js(f"(app.playItem({{ id: '{casablanca}', type: 'Movie', mediaType: 'Video', name: 'Casablanca', user: {{}} }}, {{}}), hooks.player.close())")
        time.sleep(3)
        assert h.value("hooks.player.active") is False
        assert not reports(port, casablanca), reports(port, casablanca)
        print("ok: a close beats a play still loading")

        # Playing in the window: start, pause and stop reach the server.
        h.js(f"app.playItem({{ id: '{BLADE}', type: 'Movie', mediaType: 'Video', name: 'Blade Runner', user: {{}} }}, {{}})")
        wait_for("playback starts", lambda: any(r["kind"] == "start" for r in reports(port, BLADE)), 20)
        assert h.value("app.keyContext") == "player"
        time.sleep(1.5)
        h.shot("09-player")
        h.key("playPause", 1.0)
        wait_for("a pause report", lambda: any(r.get("event") == "Pause" for r in reports(port, BLADE)), 5)
        h.key("playPause", 0.5)
        h.key("seekForwardSmall", 1.0)
        h.key("closePlayer", 1.0)
        wait_for("a stop report", lambda: any(r["kind"] == "stop" for r in reports(port, BLADE)), 5)
        assert h.value("hooks.player.active") is False and h.value("app.keyContext") == "browse"
        print("ok: window playback reports")

        # Text subtitles drawn by the window, and a picture track converted by the server.
        h.js(f"app.playItem({{ id: '{ARRIVAL}', type: 'Movie', mediaType: 'Video', name: 'Arrival', user: {{}} }}, {{ restart: true }})")
        wait_for("Arrival plays", lambda: len([r for r in reports(port, ARRIVAL) if r["kind"] == "start"]) >= 1, 20)
        h.js("hooks.player.chooseSubtitles(3)")
        wait_for("subtitle cues", lambda: h.value("hooks.player.cues.length") == 2, 5)
        h.js("hooks.player.seekTo(1)")
        time.sleep(1.5)
        h.shot("10-subtitles")
        # Picture subtitles, with the server not allowed to convert (the
        # default): the window hands the film to mpv instead.
        mpv_before = len([r for r in reports(port, ARRIVAL) if r["kind"] == "start"])
        h.js("hooks.player.chooseSubtitles(4)")
        wait_for("mpv takes over", lambda: h.value("hooks.player.active") is False, 10)
        wait_for("mpv plays it", lambda: len([r for r in reports(port, ARRIVAL) if r["kind"] == "start"]) > mpv_before, 10)
        assert all(a["enableTranscoding"] is False for a in state(port)["playbackInfo"]), "something asked the server to convert"
        print("ok: picture subtitles go to mpv; nothing asked the server to convert")

        # Allowed to convert: the same subtitles are burned in by the server.
        h.js("service.updateSettings({ playback: { allowTranscoding: true } })")
        wait_for("the setting", lambda: h.value("service.playbackPrefs.allowTranscoding") is True, 5)
        time.sleep(2)
        h.js(f"app.playItem({{ id: '{ARRIVAL}', type: 'Movie', mediaType: 'Video', name: 'Arrival', user: {{}} }}, {{ restart: true }})")
        wait_for("Arrival plays again", lambda: h.value("hooks.player.started") is True, 20)
        h.js("hooks.player.chooseSubtitles(4)")
        wait_for("a converted stream", lambda: h.value("hooks.player.info && hooks.player.info.burnedIn") is True, 10)
        assert h.value("hooks.player.info.method") == "Transcode"
        h.key("playbackInfo", 0.8)
        h.shot("11-burned-in")
        h.key("closePlayer", 1.0)
        h.js("service.updateSettings({ playback: { allowTranscoding: false } })")
        print("ok: subtitles in the window and burned in when allowed")

        # An episode: Skip intro, then Up next as the credits start.
        h.js(f"app.playItem({{ id: '{S1E2}', type: 'Episode', mediaType: 'Video', seriesId: '{HOMELAND}', user: {{}} }}, {{ restart: true }})")
        wait_for("the episode plays", lambda: any(r["kind"] == "start" for r in reports(port, S1E2)), 20)
        wait_for("the next episode is known", lambda: h.value("hooks.player.nextEpisode ? hooks.player.nextEpisode.id : ''") == S1E3, 5)
        h.js("hooks.player.seekTo(6)")
        wait_for("inside the intro", lambda: h.value("hooks.player.segment ? hooks.player.segment.type : ''") == "Intro", 5)
        time.sleep(0.5)
        h.shot("12-skip-intro")
        h.key("skipSegment", 1.0)
        assert h.value("hooks.player.position") >= 19.5
        h.js("hooks.player.seekTo(51)")
        wait_for("Up next", lambda: h.value("hooks.player.upNextShown") is True, 6)
        h.shot("13-up-next")
        h.key("skipSegment", 1.5)   # s on Up next plays the next episode
        wait_for("the next episode starts", lambda: any(r["kind"] == "start" for r in reports(port, S1E3)), 20)
        assert any(r["kind"] == "stop" for r in reports(port, S1E2))
        h.key("closePlayer", 1.0)
        print("ok: skip intro and up next")

        # Continue in mpv hands over the position (a fake mpv plays it).
        h.js(f"app.playInMpv({{ id: '{BLADE}', type: 'Movie', mediaType: 'Video', name: 'Blade Runner', user: {{ position: 5 }} }}, {{}})")
        wait_for("mpv reports", lambda: len([r for r in reports(port, BLADE) if r["method"] == "DirectPlay" and r["kind"] == "stop"]) >= 2, 15)
        print("ok: play in mpv")

        # Downloads: the button beside Play starts one, shows it coming, and
        # becomes a bin; deleting asks first and moves the file to the trash.
        control = lambda **b: urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{port}/_downloads", data=json.dumps(b).encode(),
            headers={"Content-Type": "application/json"}, method="POST")).read()
        control(throttle=60_000)
        h.js(f"app.openItem({{ id: '{BLADE}', type: 'Movie', name: 'Blade Runner' }})")
        wait_for("the film page", lambda: h.value("app.view().details ? app.view().details.id : ''") == BLADE, 10)
        h.js(f"app.downloadAction(app.view().shown, hooks.content)")
        wait_for("downloading", lambda: h.value(f"service.downloadOf('{BLADE}') ? service.downloadOf('{BLADE}').state : ''") == "downloading", 10)
        wait_for("some progress", lambda: h.value(f"service.downloadOf('{BLADE}').bytes") > 100_000, 10)
        assert "Downloading Blade Runner" in h.value("hooks.status.leftText"), h.value("hooks.status.leftText")
        h.shot("17-downloading")
        control(throttle=0)
        wait_for("downloaded", lambda: h.value(f"service.downloadOf('{BLADE}').state") == "done", 20)
        film = os.path.join(root, "home", "videos", "Omafin", "Movies", "Blade Runner (1982)", "Blade Runner (1982).mp4")
        assert os.path.getsize(film) > 1000
        time.sleep(0.6)
        h.shot("18-downloaded")
        h.js(f"app.downloadAction(app.view().shown, hooks.content)")
        assert h.value("hooks.confirm.opened") is True and "trash" in h.value("hooks.confirm.message")
        h.js("hooks.confirm.confirm()")
        wait_for("gone from downloads", lambda: h.value(f"service.downloadOf('{BLADE}') === null") is True, 10)
        assert os.path.exists(os.path.join(root, "xdg", "Trash", "files", "Blade Runner (1982)", "Blade Runner (1982).mp4"))
        assert not os.path.exists(film)
        print("ok: download, progress, bin, delete to the trash")

        # Pause and cancel from the button's menu while it downloads.
        control(throttle=40_000)
        h.js(f"app.startDownload({{ id: '{ARRIVAL}', type: 'Movie', name: 'Arrival' }})")
        wait_for("Arrival on its way", lambda: h.value(f"service.downloadOf('{ARRIVAL}') ? service.downloadOf('{ARRIVAL}').state : ''") == "downloading", 10)
        h.js(f"app.downloadAction({{ id: '{ARRIVAL}', type: 'Movie', name: 'Arrival' }}, hooks.content)")
        assert h.value("hooks.menu.items.map(function(i) { return i.id })") == ["pause", "cancel"]
        h.js("app.menuHandler('pause')")
        wait_for("paused", lambda: h.value(f"service.downloadOf('{ARRIVAL}').state") == "paused", 10)
        h.nav("back")
        h.js(f"app.downloadAction({{ id: '{ARRIVAL}', type: 'Movie', name: 'Arrival' }}, hooks.content)")
        assert h.value("hooks.menu.items.map(function(i) { return i.id })") == ["resume", "cancel"]
        h.js("app.menuHandler('cancel')")
        wait_for("cancelled", lambda: h.value(f"service.downloadOf('{ARRIVAL}') === null") is True, 10)
        h.nav("back")
        control(throttle=0)
        print("ok: pause and cancel a download")

        # A season from a show's page.
        h.js(f"app.openItem({{ id: '{HOMELAND}', type: 'Series', name: 'Homeland' }})")
        wait_for("the show page", lambda: h.value("app.view().episodes.length") == 3, 10)
        h.js("app.showItemMenu(app.view().shown, hooks.content, 10, 10)")
        labels = h.value("hooks.menu.items.map(function(i) { return i.label })")
        assert "Download Season 1 (3 episodes)" in labels, labels
        h.js("app.menuHandler('downloadSeason')")
        wait_for("the season downloaded", lambda: h.value("service.downloadsDone") == 3, 30)
        h.nav("back")
        h.nav("down")
        time.sleep(0.6)
        h.shot("19-season-downloaded")
        print("ok: a season downloads")

        # The Downloaded section lists them; with the server out of reach an
        # episode still opens and plays from its file.
        assert "Downloaded" in h.value("app.sections.map(function(s) { return s.label })")
        h.nav("go:downloaded", 1.5)
        wait_for("the downloaded grid", lambda: h.value("app.view().items ? app.view().items.length : 0") >= 1, 10)
        assert "Homeland" in h.value("app.view().items.map(function(i) { return i.name })")
        time.sleep(0.8)
        h.shot("20-downloaded")
        h.js(f"service.updateSettings({{ serverUrl: 'http://127.0.0.1:9' }})")
        wait_for("offline", lambda: h.value("service.serverError") != "", 15)
        h.js("app.openItem({ id: 'a00000000000000000000000000000d4', type: 'Episode', name: 'Episode 2', seriesId: '" + HOMELAND + "' })")
        wait_for("the episode page offline", lambda: h.value("app.view().details ? app.view().details.offline === true : false") is True, 10)
        time.sleep(0.8)
        h.shot("21-offline-episode")
        h.js("app.view().playShown(false)")
        wait_for("plays from the file", lambda: h.value("hooks.player.started") is True, 20)
        assert h.value("hooks.player.info.local") is True
        h.js("hooks.player.seekTo(20)")
        time.sleep(1.0)
        h.key("closePlayer", 1.0)
        wait_for("its place kept", lambda: (h.value("service.downloadOf('a00000000000000000000000000000d4').card.user.position") or 0) >= 19, 10)
        h.js(f"service.updateSettings({{ serverUrl: 'http://127.0.0.1:{port}' }})")
        wait_for("back online", lambda: h.value("service.serverError") == "", 15)
        wait_for("sent to the server", lambda: (state(port)["positions"].get("a00000000000000000000000000000d4") or 0) >= 19, 10)
        h.nav("go:home", 1.0)
        print("ok: Downloaded, offline details, local playback and sync")

        # Settings, and the phone-width layout.
        h.key("settings", 1.0)
        assert h.value("!!hooks.settings.item")
        h.shot("14-settings")
        h.key("settings", 0.5)
        h.nav("go:home", 1.0)
        h.js("app.narrowOverride = true")
        time.sleep(1.2)
        h.shot("15-narrow")
        h.js("app.narrowOverride = false")
        h.nav("help", 0.6)
        h.shot("16-help")
        h.nav("help", 0.3)

        # Navigation from scripts never changes anything.
        assert h.ipc("nav", "watched") == "refused" and h.ipc("nav", "play") == "refused"
        print("ok: settings, narrow layout, shortcut sheet, guarded navigation")

        errors = h.errors()
        assert not errors, "QML errors:\n" + "".join(errors[:20])
        print("ui e2e: all passed; screenshots in", shots)
    finally:
        if h:
            h.stop()
        mock.terminate()


if __name__ == "__main__":
    main()
