#!/usr/bin/env python3
"""Downloads against the mock Jellyfin: a whole film byte for byte, a
connection that drops, a backend that restarts mid-download, a file that
changes on the server, pause / resume / cancel, a file deleted behind
Omafin's back, removal to the desktop trash, a season, and the refusals.

usage: downloads_e2e.py path/to/omafin
"""
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from backend_e2e import ARRIVAL, BLADE, HOMELAND, Backend, fetch, free_port, start_mock, state, wait_for  # noqa: E402
import mock_jellyfin  # noqa: E402

CASABLANCA = "a0000000000000000000000000000066"
DUNE = "a0000000000000000000000000000067"
EDGE = "a0000000000000000000000000000068"
HUGE = "a000000000000000000000000000006a"
SEASON1 = "a00000000000000000000000000000d2"


def expected(item, version=0):
    mock_jellyfin.STATE["versions"] = {item: version}
    return mock_jellyfin.payload(item)


def control(port, **body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/_downloads", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req).read()


def entry(b, item):
    return next((e for e in b.call("downloads.list")["entries"] if e["id"] == item), None)


def wait_state(b, item, want, timeout=30):
    wait_for(f"{item[-4:]} {want}", lambda: (entry(b, item) or {}).get("state") == want, timeout)
    return entry(b, item)


def main():
    binary = os.path.abspath(sys.argv[1])
    port = free_port()
    root = tempfile.mkdtemp(prefix="omafin-dl-")
    mock = start_mock(port)
    home = os.path.join(root, "home")
    env = {"XDG_DATA_HOME": os.path.join(root, "xdg")}
    b = Backend(binary, home, env)
    url = f"http://127.0.0.1:{port}"
    videos = os.path.join(home, "videos", "Omafin")
    try:
        b.call("auth.signIn", {"url": url, "username": "Daniel", "password": "hunter2"})
        listed = b.call("downloads.list")
        assert listed["entries"] == [] and listed["root"] == videos, listed
        assert listed["free"] > 0

        # Refusals.
        b.refused("downloads.add", {"id": "../x"}, "not a valid")
        b.refused("downloads.add", {"id": HOMELAND}, "films and episodes")
        b.refused("downloads.add", {"id": HUGE}, "is free")
        b.refused("downloads.pause", {"id": BLADE}, "not being downloaded")
        print("ok: refusals")

        # A whole film, byte for byte, with its metadata beside it.
        first = b.call("downloads.add", {"id": BLADE})
        assert first["state"] == "queued" and first["size"] == mock_jellyfin.DOWNLOAD_SIZE
        done = wait_state(b, BLADE, "done")
        film = os.path.join(videos, "Movies", "Blade Runner (1982)")
        assert done["path"] == os.path.join(film, "Blade Runner (1982).mp4"), done["path"]
        assert open(done["path"], "rb").read() == expected(BLADE)
        meta = os.path.join(film, ".omafin")
        item = json.load(open(os.path.join(meta, "item.json")))
        assert item["Name"] == "Blade Runner" and "UserData" not in item, "the account's viewing record stays out of the video folder"
        assert os.stat(videos).st_mode & 0o777 == 0o700, "the download folder Omafin made is the user's alone"
        assert os.stat(meta).st_mode & 0o777 == 0o700 and os.stat(os.path.join(meta, "item.json")).st_mode & 0o777 == 0o600
        assert os.path.exists(os.path.join(meta, "primary.img")) and os.path.exists(os.path.join(meta, "backdrop.img"))
        assert not [f for f in os.listdir(film) if f.endswith(".part")]
        assert any(e.get("method") == "downloads.changed" and e["params"].get("entry", {}).get("state") == "downloading" for e in b.events)
        again = b.call("downloads.add", {"id": BLADE})
        assert again["state"] == "done", "a second add re-downloaded"
        print("ok: a film downloads whole, with its metadata")

        # The connection drops partway: the download resumes from there.
        control(port, throttle=2_000_000, dropAfter=1_000_000)
        b.call("downloads.add", {"id": ARRIVAL})
        done = wait_state(b, ARRIVAL, "done", 60)
        asked = [d["range"] for d in state(port)["downloads"] if d["item"] == ARRIVAL]
        assert asked[0] is None and asked[-1] and asked[-1].startswith("bytes=") and int(asked[-1][6:-1]) >= 900_000, asked
        assert open(done["path"], "rb").read() == expected(ARRIVAL)
        sub = os.path.join(videos, "Movies", "Arrival (2016)", ".omafin", "subtitles")
        assert sorted(os.listdir(sub)) == ["3.eng.vtt"], os.listdir(sub)
        print("ok: a dropped connection resumes where it stopped")

        # The backend stops mid-download (a crash, a reboot): it carries on.
        control(port, throttle=400_000)
        b.call("downloads.add", {"id": CASABLANCA})
        wait_for("part of Casablanca", lambda: (entry(b, CASABLANCA) or {}).get("bytes", 0) > 600_000, 20)
        b.proc.kill()
        b.proc.wait()
        control(port, throttle=0)
        b = Backend(binary, home, env)
        done = wait_state(b, CASABLANCA, "done", 60)
        asked = [d["range"] for d in state(port)["downloads"] if d["item"] == CASABLANCA]
        assert len(asked) == 2 and asked[1] and int(asked[1][6:-1]) > 0, asked
        assert open(done["path"], "rb").read() == expected(CASABLANCA)
        print("ok: a restart resumes the download")

        # The file changes on the server between parts: it starts over.
        control(port, throttle=500_000)
        b.call("downloads.add", {"id": DUNE})
        wait_for("part of Dune", lambda: (entry(b, DUNE) or {}).get("bytes", 0) > 500_000, 20)
        b.call("downloads.pause", {"id": DUNE})
        wait_state(b, DUNE, "paused")
        control(port, change=DUNE, throttle=0)
        b.call("downloads.resume", {"id": DUNE})
        done = wait_state(b, DUNE, "done", 60)
        assert open(done["path"], "rb").read() == expected(DUNE, 1), "the new file was not downloaded whole"
        print("ok: a file changed on the server is downloaded again")

        # Pause and cancel: the partial file goes, and so do the folders.
        control(port, throttle=300_000)
        b.call("downloads.add", {"id": EDGE})
        wait_for("part of Edge", lambda: (entry(b, EDGE) or {}).get("bytes", 0) > 300_000, 20)
        paused = b.call("downloads.pause", {"id": EDGE})
        wait_state(b, EDGE, "paused")
        edge_folder = os.path.join(videos, "Movies", "Edge of Tomorrow (2014)")
        assert os.path.exists(os.path.join(edge_folder, "Edge of Tomorrow (2014).mp4.part"))
        b.refused("downloads.remove", {"id": EDGE}, "cancel it instead")
        b.call("downloads.cancel", {"id": EDGE})
        assert entry(b, EDGE) is None and not os.path.exists(edge_folder), os.listdir(os.path.dirname(edge_folder))
        control(port, throttle=0)
        print("ok: pause and cancel")

        # A file deleted in the file manager shows as missing, and comes back.
        os.remove(os.path.join(film, "Blade Runner (1982).mp4"))
        assert entry(b, BLADE)["state"] == "missing"
        b.refused("downloads.cancel", {"id": BLADE}, "delete it instead")
        b.call("downloads.add", {"id": BLADE})
        done = wait_state(b, BLADE, "done")
        assert open(done["path"], "rb").read() == expected(BLADE)
        print("ok: a deleted file is noticed and can be downloaded again")

        # Removing goes to the desktop trash, folder and all.
        trashed = b.call("downloads.remove", {"id": BLADE})["trashed"]
        trash = os.path.join(root, "xdg", "Trash")
        assert trashed == [os.path.join(trash, "files", "Blade Runner (1982)")], trashed
        assert os.path.exists(os.path.join(trash, "files", "Blade Runner (1982)", "Blade Runner (1982).mp4"))
        info = open(os.path.join(trash, "info", "Blade Runner (1982).trashinfo")).read()
        assert "Path=" + film.replace(" ", "%20").replace("(", "%28").replace(")", "%29") in info, info
        assert not os.path.exists(film) and entry(b, BLADE) is None
        print("ok: removing moves the download to the trash")

        # A season: every episode, in its show's folders.
        added = b.call("downloads.addSeason", {"seriesId": HOMELAND, "seasonId": SEASON1})
        assert added == {"added": 3, "skipped": 0}, added
        season = os.path.join(videos, "Shows", "Homeland", "Season 01")
        for n in (1, 2, 3):
            ep = "a00000000000000000000000000000%x" % (0xd2 + n)
            done = wait_state(b, ep, "done", 30)
            assert done["path"] == os.path.join(season, f"S01E0{n} - Episode {n}.mp4"), done["path"]
        series_meta = os.path.join(videos, "Shows", "Homeland", ".omafin", "series")
        series_item = json.load(open(os.path.join(series_meta, "item.json")))
        assert series_item["Name"] == "Homeland" and "UserData" not in series_item
        assert os.stat(os.path.dirname(series_meta)).st_mode & 0o777 == 0o700
        assert os.stat(os.path.join(season, ".omafin")).st_mode & 0o777 == 0o700
        assert b.call("downloads.addSeason", {"seriesId": HOMELAND, "seasonId": SEASON1}) == {"added": 0, "skipped": 3}
        # Downloads play from their files, and work with the server out of reach.
        base = b.call("system.info")["mediaBase"]
        local = b.call("play.prepare", {"id": CASABLANCA})
        assert local["local"] is True and local["url"] == f"/local/{CASABLANCA}/file" and local["method"] == "DirectPlay", local
        status, _, body = fetch(base, local["url"], {"Range": "bytes=0-99"})
        assert status == 206 and body == expected(CASABLANCA)[:100]
        arrival = b.call("play.prepare", {"id": ARRIVAL, "subtitleIndex": 3})
        sub = [x for x in arrival["subtitles"] if x["index"] == 3][0]
        assert sub["url"] == f"/local/{ARRIVAL}/sub/3" and fetch(base, sub["url"])[2].startswith(b"WEBVTT")
        picture = b.call("play.prepare", {"id": ARRIVAL, "subtitleIndex": 4})
        assert picture["subtitleIndex"] is None and picture["needsMpv"] == 4, picture
        assert fetch(base, f"/local/{HOMELAND}/file")[0] == 404, "a show has no file"
        assert fetch(base, f"/local/{EDGE}/file")[0] == 404, "only downloads are served"

        b.call("settings.update", {"patch": {"serverUrl": "http://127.0.0.1:9"}})
        film = b.call("item.get", {"id": CASABLANCA})
        assert film["name"] == "Casablanca" and film["offline"] is True and film["sources"], film.get("name")
        status, headers, image = fetch(base, f"/img/{CASABLANCA}/Backdrop?tag=b2&w=800")
        assert status == 200 and len(image) > 0, "a saved picture did not stand in"
        b.refused("item.get", {"id": EDGE}, "")
        show = b.call("item.get", {"id": HOMELAND})
        assert show["offline"] is True and show["nextUp"]["index"] == 2, show.get("nextUp")
        seasons = b.call("show.seasons", {"id": HOMELAND})
        assert [x["name"] for x in seasons] == ["Season 1"] and seasons[0]["user"]["unplayed"] == 2, seasons
        assert [e["index"] for e in b.call("show.episodes", {"id": HOMELAND, "seasonId": SEASON1})] == [1, 2, 3]
        assert b.call("show.nextEpisode", {"id": "a00000000000000000000000000000d4", "seriesId": HOMELAND})["index"] == 3
        assert b.call("item.similar", {"id": CASABLANCA}) == []
        listed = b.call("downloads.items", {"sort": "name"})
        names = [c["name"] for c in listed["items"]]
        assert names == ["Arrival", "Casablanca", "Dune", "Homeland"], names
        assert [c for c in listed["items"] if c["type"] == "Series"][0]["childCount"] == 3
        assert [c["name"] for c in b.call("downloads.items", {"sort": "name", "filters": ["unplayed"]})["items"]] == ["Arrival", "Casablanca", "Homeland"]  # Dune is watched
        offline_play = b.call("play.prepare", {"id": CASABLANCA, "start": 0})
        assert offline_play["local"] is True
        sess = offline_play["session"]
        assert b.call("play.report", {"session": sess, "event": "start", "position": 0})["kept"] is True
        stopped = b.call("play.report", {"session": sess, "event": "stop", "position": 30})
        assert stopped == {"reported": False, "kept": True}, stopped
        assert entry(b, CASABLANCA)["card"]["user"]["position"] == 30
        assert state(port)["positions"].get(CASABLANCA) is None
        print("ok: downloads play from their files and show offline")

        # Back online: what was watched offline reaches the server.
        b.call("settings.update", {"patch": {"serverUrl": url}})
        b.call("server.overview")
        assert state(port)["positions"].get(CASABLANCA) == 30, state(port)["positions"]
        print("ok: offline viewing is sent when the server is back")

        b.call("downloads.remove", {"id": "a00000000000000000000000000000d3"})
        assert not os.path.exists(os.path.join(season, "S01E01 - Episode 1.mp4")) and os.path.exists(series_meta)
        for ep in ("a00000000000000000000000000000d4", "a00000000000000000000000000000d5"):
            b.call("downloads.remove", {"id": ep})
        assert not os.path.exists(os.path.join(videos, "Shows")), "the empty show folders stayed"
        print("ok: a season downloads into its show's folders, and goes again")

        # Two films of the same name and year get folders of their own, so
        # removing one never takes the other with it.
        fargo, twin = "a0000000000000000000000000000069", "a000000000000000000000000000006b"
        b.call("downloads.add", {"id": fargo})
        b.call("downloads.add", {"id": twin})
        one, two = wait_state(b, fargo, "done"), wait_state(b, twin, "done")
        assert os.path.dirname(one["path"]) != os.path.dirname(two["path"]), (one["path"], two["path"])
        b.call("downloads.remove", {"id": twin})
        assert os.path.exists(one["path"]) and entry(b, fargo)["state"] == "done"
        print("ok: same-named films keep apart")

        # A whole folder deleted in the file manager: the download just goes,
        # noticed without anyone asking (the backend watches the folders).
        shutil.rmtree(os.path.dirname(one["path"]))
        b.events.clear()
        deadline = time.time() + 6
        while time.time() < deadline and not any(e.get("method") == "downloads.changed" and e["params"].get("removed") == fargo for e in b.events):
            b.call("system.info")  # reads the events that have arrived
            time.sleep(1)
        assert any(e["params"].get("removed") == fargo for e in b.events if e.get("method") == "downloads.changed"), "the deleted folder was not noticed"
        assert entry(b, fargo) is None
        print("ok: a folder deleted in the file manager leaves Downloaded")

        print("downloads e2e: all passed")
    finally:
        b.stop()
        mock.terminate()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
