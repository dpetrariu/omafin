#!/usr/bin/env python3
"""The real backend against the mock Jellyfin: signing in (password and
Quick Connect), the library calls, marks, playback negotiation, the media
proxy and playback reports. Nothing here talks to a real server.

usage: backend_e2e.py path/to/omafin
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MOVIES = "a0000000000000000000000000000001"
ARRIVAL = "a0000000000000000000000000000064"   # gid(100): subtitles, chapters, trickplay, in progress
BLADE = "a0000000000000000000000000000065"
HOMELAND = "a00000000000000000000000000000c8"  # gid(200)
S1E2 = "a00000000000000000000000000000d4"      # gid(212): next up, has an intro


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(what, check, timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if check():
                return
        except Exception:
            pass
        time.sleep(0.2)
    raise AssertionError("timed out waiting for " + what)


def _ping(port):
    return urllib.request.urlopen(f"http://127.0.0.1:{port}/System/Info/Public", timeout=2).status == 200


def make_media(folder):
    """A one-minute test video (and an HLS segment of it), if ffmpeg exists."""
    if not shutil.which("ffmpeg"):
        return None
    os.makedirs(folder, exist_ok=True)
    mp4 = os.path.join(folder, "test.mp4")
    if not os.path.exists(mp4) or os.path.getsize(mp4) < 1000:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=60",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=60", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-shortest", "-y", mp4], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", mp4, "-c", "copy", "-f", "mpegts", "-y", os.path.join(folder, "test.ts")], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=1600x900:duration=1", "-frames:v", "1", "-y", os.path.join(folder, "test.png")], check=True)
    return folder


def start_mock(port, media=None):
    args = [sys.executable, "-I", os.path.join(HERE, "mock_jellyfin.py"), str(port), "--seed"]
    if media:
        args += ["--media", media]
    proc = subprocess.Popen(args)
    wait_for("the mock is up", lambda: _ping(port), 10)
    return proc


def state(port):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/_state"))


def approve(port, code):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/_approve", data=json.dumps({"code": code}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req).read()


class Backend:
    def __init__(self, binary, home, env=None):
        self.proc = subprocess.Popen([binary, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     env=dict(os.environ, OMAFIN_HOME=home, **(env or {})), text=True)
        self.n = 0
        self.events = []

    def call(self, method, params=None):
        self.n += 1
        rid = str(self.n)
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise AssertionError("backend exited")
            msg = json.loads(line)
            if "id" not in msg:
                self.events.append(msg)
                continue
            if msg["id"] == rid:
                if "error" in msg:
                    raise RpcError(msg["error"])
                return msg["result"]

    def refused(self, method, params, contains=""):
        try:
            self.call(method, params)
        except RpcError as e:
            assert contains.lower() in e.message.lower(), f"{method}: {e.message!r} lacks {contains!r}"
            return e
        raise AssertionError(f"{method} {params} was not refused")

    def stop(self):
        try:
            self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": "x", "method": "system.shutdown"}) + "\n")
            self.proc.stdin.flush()
            self.proc.wait(5)
        except Exception:
            self.proc.kill()


class RpcError(Exception):
    def __init__(self, error):
        super().__init__(error.get("message"))
        self.code = error.get("code")
        self.message = error.get("message", "")


def fetch(base, path, headers=None):
    req = urllib.request.Request(base + path, headers=headers or {})
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, b""


def main():
    binary = os.path.abspath(sys.argv[1])
    port = free_port()
    root = tempfile.mkdtemp(prefix="omafin-e2e-")
    media = make_media(os.path.join(root, "media"))
    mock = start_mock(port, media)
    home = os.path.join(root, "home")
    b = Backend(binary, home)
    url = f"http://127.0.0.1:{port}"
    try:
        info = b.call("system.info")
        assert info["configured"] is False and info["apiVersion"] == 1
        b.refused("home", {}, "sign in")
        b.refused("nope.method", {}, "unknown method")

        # Probing and signing in.
        probe = b.call("auth.probe", {"url": f"127.0.0.1:{port}/web/"})
        assert probe["url"] == url and probe["name"] == "Mock Jellyfin" and probe["quickConnect"] is True, probe
        assert probe["users"] == ["Daniel"]
        b.refused("auth.probe", {"url": "ftp://x"}, "http")
        b.refused("auth.signIn", {"url": url, "username": "Daniel", "password": "wrong"}, "did not work")
        b.refused("auth.signIn", {"url": url, "username": "", "password": "x"}, "user name")
        signed = b.call("auth.signIn", {"url": url, "username": "Daniel", "password": "hunter2"})
        assert signed["signedIn"] is True and signed["settings"]["userName"] == "Daniel" and signed["settings"]["serverUrl"] == url
        assert len(signed["settings"]["deviceId"]) == 32
        token_file = os.path.join(home, "config", "token")
        assert os.stat(token_file).st_mode & 0o777 == 0o600
        print("ok: probe and password sign-in")

        # Signing out ends the session on the server and here.
        out = b.call("auth.signOut")
        assert out["signedIn"] is False and state(port)["logouts"] == 1 and not os.path.exists(token_file)
        b.refused("home", {}, "sign in")

        # Quick Connect: a code, approved elsewhere, then signed in.
        b.refused("auth.quickConnectPoll", {}, "start quick connect")
        code = b.call("auth.quickConnectStart", {"url": url})["code"]
        assert len(code) == 6
        assert b.call("auth.quickConnectPoll")["state"] == "waiting"
        approve(port, code)
        done = b.call("auth.quickConnectPoll")
        assert done["state"] == "signedIn" and done["settings"]["signedIn"] is True
        print("ok: sign-out and Quick Connect")

        # The home page.
        overview = b.call("server.overview")
        assert overview["server"]["name"] == "Mock Jellyfin" and [v["name"] for v in overview["views"]] == ["Movies", "TV Shows", "Collections"]
        home_page = b.call("home")
        assert [i["id"] for i in home_page["resume"]] == [ARRIVAL], home_page["resume"]
        assert [i["id"] for i in home_page["nextUp"]] == [S1E2]
        episode = home_page["nextUp"][0]
        assert episode["seriesName"] == "Homeland" and episode["images"]["backdrop"]["id"] == HOMELAND and episode["images"]["series"]["tag"] == "sp0"
        assert [r["title"] for r in home_page["latest"]] == ["Movies", "TV Shows"]   # collections have no "new" row
        resume = home_page["resume"][0]
        assert resume["user"]["position"] == 4 and round(resume["user"]["percent"]) == 7
        print("ok: home rows")

        # Lists, with sorting, filters and refusals.
        page = b.call("items.list", {"parentId": MOVIES, "types": "Movie", "sort": "name", "limit": 4})
        assert page["total"] == 6 and [i["name"] for i in page["items"]] == ["Arrival", "Blade Runner", "Casablanca", "Dune"]
        page2 = b.call("items.list", {"parentId": MOVIES, "types": "Movie", "sort": "name", "start": 4, "limit": 4})
        assert [i["name"] for i in page2["items"]] == ["Edge of Tomorrow", "Fargo"]
        newest = b.call("items.list", {"parentId": MOVIES, "types": "Movie", "sort": "added", "descending": True, "limit": 1})
        assert newest["items"][0]["name"] == "Fargo"
        fav = b.call("items.list", {"types": "Movie,Series,Episode", "filters": ["favorite"], "recursive": True})
        assert [i["name"] for i in fav["items"]] == ["Casablanca"]
        unwatched = b.call("items.list", {"parentId": MOVIES, "types": "Movie", "filters": ["unplayed"]})
        assert "Dune" not in [i["name"] for i in unwatched["items"]] and unwatched["total"] == 5
        scifi = b.call("items.list", {"parentId": MOVIES, "types": "Movie", "genres": ["Science Fiction"]})
        assert scifi["total"] == 4
        assert "Science Fiction" in b.call("genres.list", {"parentId": MOVIES})
        b.refused("items.list", {"parentId": "../../Users"}, "not a valid")
        b.refused("items.list", {"sort": "DROP TABLE"}, "unknown sort")
        b.refused("items.list", {"types": "User"}, "unknown item type")
        b.refused("items.list", {"filters": ["IsEverything"]}, "unknown filter")
        print("ok: lists, sorting, filters and refusals")

        # A film page, a show page, seasons, episodes, next episode.
        film = b.call("item.get", {"id": ARRIVAL})
        assert film["tagline"] == "Arrival, the film." and film["genres"] == ["Drama", "Science Fiction"]
        assert film["links"]["Imdb"].startswith("https://www.imdb.com/title/") and film["trailers"][0].startswith("https://")
        assert [p["name"] for p in film["people"]] == ["Ada Actor", "Dee Rector"] and film["chapters"][1]["start"] == 30
        assert film["trickplay"]["width"] == 160 and film["sources"][0]["streams"][3]["isText"] is True
        show = b.call("item.get", {"id": HOMELAND})
        assert show["nextUp"]["id"] == S1E2 and show["endYear"] == 2020
        seasons = b.call("show.seasons", {"id": HOMELAND})
        assert [s["name"] for s in seasons] == ["Season 1", "Season 2"] and seasons[0]["user"]["unplayed"] == 2
        eps = b.call("show.episodes", {"id": HOMELAND, "seasonId": seasons[1]["id"]})
        assert [e["index"] for e in eps] == [1, 2, 3] and eps[0]["parentIndex"] == 2
        nxt = b.call("show.nextEpisode", {"id": eps[2]["id"], "seriesId": HOMELAND})
        assert nxt is None
        nxt = b.call("show.nextEpisode", {"id": S1E2, "seriesId": HOMELAND})
        assert nxt["index"] == 3 and nxt["parentIndex"] == 1
        assert b.call("item.similar", {"id": ARRIVAL})
        b.refused("item.get", {"id": "x"}, "not a valid")
        found = b.call("search", {"term": "blade"})
        assert [i["name"] for i in found["movies"]] == ["Blade Runner"]
        assert b.call("search", {"term": "ada"})["people"][0]["name"] == "Ada Actor"
        print("ok: details, seasons, episodes and search")

        # Marks change the server, and say what they changed.
        r = b.call("item.setPlayed", {"id": BLADE, "played": True})
        assert r["played"] is True and BLADE in state(port)["played"]
        r = b.call("item.setPlayed", {"id": BLADE, "played": False})
        assert r["played"] is False and BLADE not in state(port)["played"]
        r = b.call("item.setFavorite", {"id": BLADE, "favorite": True})
        assert r["favorite"] is True and BLADE in state(port)["favorites"]
        b.call("item.setFavorite", {"id": BLADE, "favorite": False})
        b.refused("item.setPlayed", {"id": BLADE}, "say whether")
        b.call("item.setPlayed", {"id": ARRIVAL, "played": True})
        undone = b.call("item.setPlayed", {"id": ARRIVAL, "played": False, "restorePosition": 4})
        assert undone["position"] == 4 and state(port)["positions"][ARRIVAL] == 4
        b.call("item.clearResume", {"id": ARRIVAL})
        assert ARRIVAL not in state(port)["positions"]
        print("ok: watched, favourite and Continue watching marks")

        # Playback: direct play through the proxy, the token never in a URL.
        base = info["mediaBase"]
        direct = b.call("play.prepare", {"id": BLADE, "start": 3})
        assert direct["method"] == "DirectPlay" and direct["hls"] is False and direct["start"] == 3
        assert direct["url"].startswith("/jf/Videos/" + BLADE + "/stream?static=true") and "ApiKey" not in direct["url"]
        status, headers, body = fetch(base, direct["url"], {"Range": "bytes=0-99"})
        assert status == 206 and len(body) == (100 if media else 64), (status, len(body))
        print("ok: direct play")

        # Picture subtitles in the window: the server converts, the URL is clean.
        burned = b.call("play.prepare", {"id": ARRIVAL, "subtitleIndex": 4})
        assert burned["method"] == "Transcode" and burned["burnedIn"] is True and burned["hls"] is True, burned
        assert "ApiKey" not in burned["url"] and "SubtitleStreamIndex=4" in burned["url"]
        status, _, playlist = fetch(base, burned["url"])
        assert status == 200 and b"ApiKey" not in playlist and b"main.m3u8" in playlist, playlist
        master_dir = burned["url"].split("?")[0].rsplit("/", 1)[0]
        status, _, main_list = fetch(base, master_dir + "/main.m3u8?MediaSourceId=" + ARRIVAL)
        assert status == 200 and b"ApiKey" not in main_list and b"hls1/main/0.ts" in main_list
        status, _, seg = fetch(base, master_dir + "/hls1/main/0.ts")
        assert status == 200 and len(seg) > 0
        text = [s for s in burned["subtitles"] if s["index"] == 3][0]
        assert text["picture"] is False and text["url"].endswith("/Subtitles/3/0/Stream.vtt")
        status, _, vtt = fetch(base, text["url"])
        assert status == 200 and vtt.startswith(b"WEBVTT")
        assert [s["picture"] for s in burned["subtitles"]] == [False, True]
        capped = b.call("play.prepare", {"id": BLADE, "maxBitrate": 100000})
        assert capped["method"] == "Transcode" and capped["transcodeReasons"] == ["ContainerBitrateExceedsLimit"]
        forced = b.call("play.prepare", {"id": BLADE, "transcode": True})
        assert forced["method"] == "Transcode"
        b.refused("play.prepare", {"id": HOMELAND}, "films and episodes")
        print("ok: transcodes, playlists without the token, subtitles")

        # The proxy only reaches videos, images and nothing else.
        for bad in ["/jf/Users/" + BLADE + "/x", "/jf/Videos/" + BLADE + "/../../System/Info", "/jf/Videos/" + BLADE + "/%2e%2e/x",
                    "/jf/Videos/nope/stream", "/img/" + BLADE + "/Primary", "/img/" + BLADE + "/Primary?tag=../x"]:
            assert fetch(base, bad)[0] == 404, bad
        assert fetch(base.rsplit("/", 1)[0], "/wrongtoken/img/" + BLADE + "/Primary?tag=t1")[0] == 404
        status, headers, image = fetch(base, "/img/" + BLADE + "/Primary?tag=p1&w=300")
        assert status == 200 and image.startswith(b"\x89PNG") and headers["content-type"] == "image/png"
        assert fetch(base, "/img/" + BLADE + "/Primary?tag=p1&w=300")[0] == 200   # from the cache
        status, _, tile = fetch(base, "/jf/Videos/" + ARRIVAL + "/Trickplay/160/0.jpg?mediaSourceId=" + ARRIVAL)
        assert status == 200 and len(tile) > 0
        assert b.call("cache.info")["bytes"] > 0
        print("ok: proxy routes and refusals")

        # Reports: start, progress (throttled), pause, stop; another session's are ignored.
        ep = b.call("play.prepare", {"id": S1E2})
        assert [s["type"] for s in ep["segments"]] == ["Intro", "Outro"] and ep["segments"][0]["end"] == 20
        sess = ep["session"]
        assert b.call("play.report", {"session": "other", "event": "start", "position": 0})["reported"] is False
        assert b.call("play.report", {"session": sess, "event": "progress", "position": 1})["reported"] is False  # before start
        assert b.call("play.report", {"session": sess, "event": "start", "position": 0})["reported"] is True
        assert b.call("play.report", {"session": sess, "event": "progress", "position": 2})["reported"] is False  # too soon
        assert b.call("play.report", {"session": sess, "event": "pause", "position": 5})["reported"] is True
        b.refused("play.report", {"session": sess, "event": "explode", "position": 5}, "unknown playback event")
        assert b.call("play.report", {"session": sess, "event": "stop", "position": 6.5})["reported"] is True
        reports = [r for r in state(port)["reports"] if r["session"] == sess]
        assert [r["kind"] for r in reports] == ["start", "progress", "stop"], reports
        assert reports[1]["event"] == "Pause" and reports[1]["paused"] is True and reports[2]["position"] == 6.5
        assert reports[0]["method"] == "DirectPlay" and reports[0]["item"] == S1E2
        assert state(port)["positions"][S1E2] == 6.5
        print("ok: playback reports")

        # A session that started is stopped when the next one starts.
        one = b.call("play.prepare", {"id": BLADE})
        b.call("play.report", {"session": one["session"], "event": "start", "position": 0})
        b.call("play.prepare", {"id": ARRIVAL})
        assert [r["kind"] for r in state(port)["reports"] if r["session"] == one["session"]] == ["start", "stop"]
        print("ok: a new session ends the old one")

        # mpv: started with a socket, given the proxy URL (no token), reported for.
        b.stop()
        mpv_log = os.path.join(root, "mpv.log")
        b = Backend(binary, home, {"PATH": os.path.join(HERE, "fakebin") + os.pathsep + os.environ["PATH"], "FAKE_MPV_LOG": mpv_log})
        assert b.call("system.info")["mpv"] is True
        handed = b.call("play.mpv", {"id": ARRIVAL, "start": 2, "subtitleIndex": 3, "audioIndex": 2})
        assert handed["url"] is None and handed["session"]
        wait_for("mpv to finish", lambda: any(r["kind"] == "stop" and r["session"] == handed["session"] for r in state(port)["reports"]), 15)
        lines = [json.loads(l) for l in open(mpv_log)]
        argv = lines[0]["argv"]
        assert not any("ApiKey" in a or "Token" in a for a in argv) and "--idle=once" in argv
        load = next(l["command"] for l in lines if "command" in l and l["command"][0] == "loadfile")
        assert load[1].startswith("http://127.0.0.1:") and "/jf/Videos/" + ARRIVAL + "/stream" in load[1] and "ApiKey" not in load[1]
        # Jellyfin stream 2 is the file's second audio track, 3 its first subtitle track.
        assert "start=2" in load[4] and "aid=2" in load[4] and "sid=1" in load[4], load
        mine = [r for r in state(port)["reports"] if r["session"] == handed["session"]]
        assert mine[0]["kind"] == "start" and mine[-1]["kind"] == "stop" and mine[-1]["position"] == 14, mine
        assert any(r["event"] == "Pause" for r in mine)
        wait_for("the playback event", lambda: any(e.get("method") == "playback.changed" and e["params"]["state"] == "stopped" for e in b.events) or b.call("play.status") is None, 5)
        print("ok: mpv handoff and its reports")

        # Settings: only known keys, validated.
        b.refused("settings.update", {"patch": {"userId": "x"}}, "unknown setting")
        b.refused("settings.update", {"patch": {"playback": {"player": "vlc"}}}, "expected one of")
        s = b.call("settings.update", {"patch": {"playback": {"skipIntro": "auto", "audioLanguage": "ENG"}}})
        assert s["settings"]["playback"]["skipIntro"] == "auto" and s["settings"]["playback"]["audioLanguage"] == "eng"
        print("ok: settings")

        # A rejected session reads as "signed out".
        with open(os.path.join(home, "config", "token"), "w") as f:
            f.write("0" * 32)
        b.stop()
        b = Backend(binary, home)
        e = b.refused("home", {}, "signed this computer out")
        assert e.code == -32002
        print("ok: an expired session says so")
        print("backend e2e: all passed")
    finally:
        b.stop()
        mock.terminate()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
