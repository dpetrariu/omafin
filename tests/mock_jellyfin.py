#!/usr/bin/env python3
"""An in-memory Jellyfin server for Omafin's tests.

It answers the endpoints Omafin calls with the shapes a real Jellyfin 12
server returns (checked with read-only calls), keeps watched marks,
favourites, resume positions and playback reports in memory, and exposes
them at GET /_state so tests can assert on what the window did.

usage: mock_jellyfin.py PORT [--seed] [--media DIR]

--media DIR holds test.mp4, test.ts and test.png (tests make them with
ffmpeg); without it the stream endpoints answer with a few bytes.
"""
import json
import os
import re
import secrets
import struct
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TICKS = 10_000_000
SERVER_ID = "b5bc49c0d5bc4cde8391f85fc2d13667"
USER_ID = "11375ca4eaff4841ac93e34b37f061a0"
PASSWORD = "hunter2"

LOCK = threading.Lock()
STATE = {
    "items": {},        # id -> item (full, Jellyfin-shaped)
    "user": {},         # id -> user data
    "tokens": {},       # token -> user id
    "quick": {},        # secret -> { code, authorized }
    "reports": [],      # playback reports in order
    "logouts": 0,
    "requests": [],     # method, path (writes only)
    "playbackInfo": [], # what each PlaybackInfo asked for
}
MEDIA = {"dir": None}


def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(kind, data):
        c = kind + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def gid(n):
    return "%032x" % (0xA0000000000000000000000000000000 + n)


# ---------------------------------------------------------------- seed

VIEWS = {"movies": gid(1), "tvshows": gid(2), "boxsets": gid(3)}


def add(item):
    item.setdefault("ServerId", SERVER_ID)
    item.setdefault("ImageTags", {"Primary": "tag" + item["Id"][-6:]})
    item.setdefault("BackdropImageTags", [])
    STATE["items"][item["Id"]] = item
    STATE["user"].setdefault(item["Id"], {"PlaybackPositionTicks": 0, "PlayCount": 0, "IsFavorite": False, "Played": False})
    return item


def video_source(item_id, subs=False, container="mp4"):
    streams = [
        {"Type": "Video", "Index": 0, "Codec": "h264", "Width": 320, "Height": 240, "DisplayTitle": "240p H264 SDR", "VideoRangeType": "SDR", "IsDefault": True},
        {"Type": "Audio", "Index": 1, "Codec": "aac", "Language": "eng", "DisplayTitle": "English - AAC - Stereo - Default", "IsDefault": True, "Channels": 2},
    ]
    if subs:
        streams += [
            {"Type": "Audio", "Index": 2, "Codec": "ac3", "Language": "deu", "DisplayTitle": "German - Dolby Digital - 5.1", "IsDefault": False, "Channels": 6},
            {"Type": "Subtitle", "Index": 3, "Codec": "subrip", "Language": "eng", "DisplayTitle": "English - SUBRIP", "IsTextSubtitleStream": True, "IsDefault": False},
            {"Type": "Subtitle", "Index": 4, "Codec": "PGSSUB", "Language": "deu", "DisplayTitle": "German - PGSSUB", "IsTextSubtitleStream": False, "IsDefault": False},
        ]
    return [{"Id": item_id, "Container": container, "Name": "test", "Size": 123456, "Bitrate": 900000, "RunTimeTicks": 60 * TICKS,
             "ETag": "etag" + item_id[-6:], "MediaStreams": streams, "DefaultAudioStreamIndex": 1, "DefaultSubtitleStreamIndex": -1,
             "SupportsDirectPlay": True, "SupportsDirectStream": True, "SupportsTranscoding": True}]


def seed():
    for kind, vid in VIEWS.items():
        add({"Id": vid, "Name": {"movies": "Movies", "tvshows": "TV Shows", "boxsets": "Collections"}[kind], "Type": "CollectionFolder",
             "CollectionType": kind, "IsFolder": True, "ChildCount": 0})
    films = [
        ("Arrival", 2016, ["Drama", "Science Fiction"], 7.9),
        ("Blade Runner", 1982, ["Science Fiction"], 8.1),
        ("Casablanca", 1942, ["Drama", "Romance"], 8.5),
        ("Dune", 2021, ["Science Fiction", "Adventure"], 8.0),
        ("Edge of Tomorrow", 2014, ["Action", "Science Fiction"], 7.9),
        ("Fargo", 1996, ["Crime", "Drama"], 8.1),
    ]
    for i, (name, year, genres, rating) in enumerate(films):
        mid = gid(100 + i)
        add({"Id": mid, "Name": name, "SortName": name.lower(), "Type": "Movie", "MediaType": "Video", "IsFolder": False, "ParentId": VIEWS["movies"],
             "ProductionYear": year, "PremiereDate": "%d-06-01T00:00:00.0000000Z" % year, "RunTimeTicks": 60 * TICKS, "CommunityRating": rating,
             "OfficialRating": "PG-13", "Genres": genres, "Overview": "A film called %s." % name, "Taglines": ["%s, the film." % name] if i == 0 else [],
             "DateCreated": "2026-10-%02dT10:00:00.0000000Z" % (10 + i),
             "ImageTags": {"Primary": "p%d" % i, "Logo": "l%d" % i, "Thumb": "t%d" % i}, "BackdropImageTags": ["b%d" % i],
             "People": [{"Name": "Ada Actor", "Id": gid(900), "Role": "Lead", "Type": "Actor", "PrimaryImageTag": "pp"},
                        {"Name": "Dee Rector", "Id": gid(901), "Type": "Director"}],
             "Studios": [{"Name": "Mock Pictures", "Id": gid(950)}], "ProviderIds": {"Imdb": "tt00%05d" % i, "Tmdb": str(1000 + i)},
             "RemoteTrailers": [{"Url": "https://www.youtube.com/watch?v=mock%d" % i}] if i == 0 else [],
             "MediaSources": video_source(mid, subs=(i == 0), container="mkv" if i == 0 else "mp4"),
             "Chapters": [{"StartPositionTicks": 0, "Name": "Opening"}, {"StartPositionTicks": 30 * TICKS, "Name": "The middle"}] if i == 0 else [],
             "Trickplay": {mid: {"160": {"Width": 160, "Height": 90, "TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 60, "Interval": 1000}}} if i == 0 else {},
             "LocalTrailerCount": 0})
    STATE["user"][gid(100)].update({"PlaybackPositionTicks": 4 * TICKS, "PlayedPercentage": 33.3, "LastPlayedDate": "2026-10-20T20:00:00.0000000Z"})
    STATE["user"][gid(102)].update({"IsFavorite": True})
    STATE["user"][gid(103)].update({"Played": True, "PlayCount": 1})
    add({"Id": gid(900), "Name": "Ada Actor", "Type": "Person", "IsFolder": False, "ImageTags": {"Primary": "pp"}})

    shows = [("Homeland", 2011, "Ended", 2), ("Severance", 2022, "Continuing", 1)]
    for s, (name, year, status, seasons) in enumerate(shows):
        sid = gid(200 + s * 50)
        add({"Id": sid, "Name": name, "SortName": name.lower(), "Type": "Series", "IsFolder": True, "ParentId": VIEWS["tvshows"],
             "ProductionYear": year, "EndDate": "2020-04-25T00:00:00.0000000Z" if status == "Ended" else None, "Status": status,
             "CommunityRating": 8.6, "OfficialRating": "TV-MA", "Genres": ["Drama", "Thriller"], "Overview": "A show called %s." % name,
             "DateCreated": "2026-10-0%dT10:00:00.0000000Z" % (1 + s),
             "ImageTags": {"Primary": "sp%d" % s, "Logo": "sl%d" % s}, "BackdropImageTags": ["sb%d" % s],
             "People": [{"Name": "Ada Actor", "Id": gid(900), "Role": "Agent", "Type": "Actor"}], "ProviderIds": {"Tmdb": str(2000 + s)}})
        for n in range(1, seasons + 1):
            season = gid(200 + s * 50 + n * 10)
            add({"Id": season, "Name": "Season %d" % n, "Type": "Season", "IsFolder": True, "ParentId": sid, "SeriesId": sid, "SeriesName": name,
                 "IndexNumber": n, "ImageTags": {"Primary": "ssp%d%d" % (s, n)}})
            for e in range(1, 4):
                eid = gid(200 + s * 50 + n * 10 + e)
                add({"Id": eid, "Name": "Episode %d" % e, "Type": "Episode", "MediaType": "Video", "IsFolder": False, "ParentId": season,
                     "SeriesId": sid, "SeriesName": name, "SeasonId": season, "SeasonName": "Season %d" % n, "IndexNumber": e, "ParentIndexNumber": n,
                     "RunTimeTicks": 60 * TICKS, "PremiereDate": "%d-10-0%dT22:00:00.0000000Z" % (year + n - 1, e), "Overview": "Episode %d of %s." % (e, name),
                     "DateCreated": "2026-10-0%dT11:00:00.0000000Z" % (1 + s),
                     "ImageTags": {"Primary": "ep%d%d%d" % (s, n, e)}, "SeriesPrimaryImageTag": "sp%d" % s,
                     "ParentBackdropItemId": sid, "ParentBackdropImageTags": ["sb%d" % s], "ParentLogoItemId": sid, "ParentLogoImageTag": "sl%d" % s,
                     "MediaSources": video_source(eid)})
    # Homeland: S1E1 watched, so S1E2 is next up.
    STATE["user"][gid(211)].update({"Played": True, "PlayCount": 1, "LastPlayedDate": "2026-10-19T20:00:00.0000000Z"})
    # The intro and credits of Homeland S1E2.
    STATE["segments"] = {gid(212): [{"Type": "Intro", "StartTicks": 5 * TICKS, "EndTicks": 20 * TICKS}, {"Type": "Outro", "StartTicks": 50 * TICKS, "EndTicks": 60 * TICKS}]}

    box = gid(300)
    add({"Id": box, "Name": "Sci-fi classics", "Type": "BoxSet", "IsFolder": True, "ParentId": VIEWS["boxsets"], "ChildCount": 2,
         "ImageTags": {"Primary": "bx"}})
    STATE["children"] = {box: [gid(101), gid(103)]}


# ---------------------------------------------------------------- shaping

def with_user(item):
    out = dict(item)
    data = dict(STATE["user"].get(item["Id"], {}))
    data["ItemId"] = item["Id"]
    data["Key"] = item["Id"]
    if item["Type"] in ("Series", "Season"):
        eps = episodes_of(item["Id"]) if item["Type"] == "Series" else [e for e in all_items("Episode") if e.get("SeasonId") == item["Id"]]
        unplayed = sum(1 for e in eps if not STATE["user"][e["Id"]]["Played"])
        data["UnplayedItemCount"] = unplayed
        data["Played"] = unplayed == 0 and len(eps) > 0
        out["ChildCount"] = len(eps) if item["Type"] == "Season" else len([s for s in all_items("Season") if s["SeriesId"] == item["Id"]])
    if item.get("RunTimeTicks") and data.get("PlaybackPositionTicks"):
        data["PlayedPercentage"] = data["PlaybackPositionTicks"] / item["RunTimeTicks"] * 100
    out["UserData"] = data
    return out


def all_items(kind=None):
    return [i for i in STATE["items"].values() if kind is None or i["Type"] == kind]


def episodes_of(series_id):
    eps = [e for e in all_items("Episode") if e["SeriesId"] == series_id]
    return sorted(eps, key=lambda e: (e["ParentIndexNumber"], e["IndexNumber"]))


def strip(item, fields):
    out = with_user(item)
    for heavy in ("MediaSources", "People", "Chapters", "Trickplay", "RemoteTrailers", "Studios", "ProviderIds", "Taglines"):
        out.pop(heavy, None)
    if "Overview" not in fields:
        out.pop("Overview", None)
    if "Genres" not in fields:
        out.pop("Genres", None)
    return out


def page(items, q):
    start = int(q.get("startIndex", ["0"])[0])
    limit = int(q.get("limit", ["100"])[0])
    return {"Items": items[start:start + limit], "TotalRecordCount": len(items), "StartIndex": start}


def next_up(series_id=None):
    out = []
    for series in all_items("Series"):
        if series_id and series["Id"] != series_id:
            continue
        eps = episodes_of(series["Id"])
        watched = [i for i, e in enumerate(eps) if STATE["user"][e["Id"]]["Played"]]
        if not watched:
            continue
        nxt = watched[-1] + 1
        if nxt < len(eps) and STATE["user"][eps[nxt]["Id"]]["PlaybackPositionTicks"] == 0:
            out.append(eps[nxt])
    return out


# ---------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list, bool)) or body is None:
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def token(self, q):
        auth = self.headers.get("Authorization", "")
        m = re.search(r'Token="([^"]*)"', auth)
        if m:
            return m.group(1)
        return (q.get("ApiKey") or q.get("api_key") or [""])[0]

    def authed(self, q):
        return self.token(q) in STATE["tokens"]

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        url = urlparse(self.path)
        path, q = url.path, parse_qs(url.query)
        body = self.body() if method in ("POST", "DELETE") else {}
        with LOCK:
            try:
                self.dispatch(method, path, q, body)
            except BrokenPipeError:
                pass

    def dispatch(self, method, path, q, body):
        # ------------------------------------------------ test hooks
        if path == "/_state":
            return self.send(200, {
                "played": {k: v["Played"] for k, v in STATE["user"].items() if v["Played"]},
                "favorites": [k for k, v in STATE["user"].items() if v["IsFavorite"]],
                "positions": {k: v["PlaybackPositionTicks"] / TICKS for k, v in STATE["user"].items() if v["PlaybackPositionTicks"]},
                "reports": STATE["reports"], "logouts": STATE["logouts"], "tokens": len(STATE["tokens"]),
                "quick": [{"code": v["code"], "authorized": v["authorized"]} for v in STATE["quick"].values()],
                "writes": STATE["requests"],
                "playbackInfo": STATE["playbackInfo"],
            })
        if path == "/_approve" and method == "POST":
            for v in STATE["quick"].values():
                if v["code"] == body.get("code"):
                    v["authorized"] = True
                    return self.send(200, True)
            return self.send(404, {"detail": "no such code"})

        # ------------------------------------------------ public
        if path == "/System/Info/Public":
            return self.send(200, {"LocalAddress": "http://127.0.0.1", "ServerName": "Mock Jellyfin", "Version": "12.2.0",
                                   "ProductName": "Jellyfin Server", "Id": SERVER_ID, "StartupWizardCompleted": True})
        if path == "/QuickConnect/Enabled":
            return self.send(200, True)
        if path == "/Users/Public":
            return self.send(200, [{"Name": "Daniel", "Id": USER_ID, "HasPassword": True}])
        if path == "/Users/AuthenticateByName" and method == "POST":
            if body.get("Username") != "Daniel" or body.get("Pw") != PASSWORD:
                return self.send(401, "Error processing request.", "text/plain")
            return self.send(200, self.session())
        if path == "/QuickConnect/Initiate" and method == "POST":
            secret = secrets.token_hex(32).upper()
            code = "%06d" % secrets.randbelow(1000000)
            STATE["quick"][secret] = {"code": code, "authorized": False}
            return self.send(200, {"Authenticated": False, "Secret": secret, "Code": code})
        if path == "/QuickConnect/Connect":
            entry = STATE["quick"].get(q.get("secret", [""])[0])
            if not entry:
                return self.send(404, {"detail": "Unknown secret"})
            return self.send(200, {"Authenticated": entry["authorized"], "Code": entry["code"]})
        if path == "/Users/AuthenticateWithQuickConnect" and method == "POST":
            entry = STATE["quick"].get(body.get("Secret", ""))
            if not entry or not entry["authorized"]:
                return self.send(401, "")
            del STATE["quick"][body["Secret"]]
            return self.send(200, self.session())

        # Images need no sign-in on Jellyfin either.
        m = re.match(r"^/Items/([0-9a-f]{32})/Images/(\w+)$", path)
        if m and method == "GET":
            item = STATE["items"].get(m.group(1))
            if not item:
                return self.send(404, b"", "text/plain")
            shade = int(m.group(1)[-2:], 16)
            colors = {"Primary": (40 + shade % 160, 80, 160), "Backdrop": (30, 60 + shade % 120, 90), "Logo": (230, 200, 60), "Thumb": (120, 60, 60)}
            return self.send(200, png(64 if m.group(2) != "Backdrop" else 160, 96 if m.group(2) == "Primary" else 90, colors.get(m.group(2), (90, 90, 90))), "image/png")

        # ------------------------------------------------ signed in
        if not self.authed(q):
            return self.send(401, "")
        if method != "GET":
            STATE["requests"].append(method + " " + path)

        if path == "/Users/Me":
            return self.send(200, {"Name": "Daniel", "Id": USER_ID, "ServerId": SERVER_ID, "Policy": {"IsAdministrator": False}})
        if path == "/Sessions/Logout" and method == "POST":
            STATE["tokens"].pop(self.token(q), None)
            STATE["logouts"] += 1
            return self.send(204, b"")
        if path == "/UserViews":
            views = [with_user(STATE["items"][v]) for v in VIEWS.values()]
            return self.send(200, {"Items": views, "TotalRecordCount": len(views), "StartIndex": 0})
        if path == "/UserItems/Resume":
            items = [i for i in all_items() if i.get("MediaType") == "Video" and STATE["user"][i["Id"]]["PlaybackPositionTicks"] > 0 and not STATE["user"][i["Id"]]["Played"]]
            items.sort(key=lambda i: STATE["user"][i["Id"]].get("LastPlayedDate", ""), reverse=True)
            return self.send(200, page([strip(i, "Overview") for i in items], q))
        if path == "/Shows/NextUp":
            items = next_up(q.get("seriesId", [None])[0])
            return self.send(200, page([strip(i, "Overview") for i in items], q))
        if path == "/Items/Latest":
            parent = q.get("parentId", [""])[0]
            items = [i for i in all_items() if i.get("ParentId") == parent and i["Type"] in ("Movie", "Series", "BoxSet")]
            items.sort(key=lambda i: i.get("DateCreated", ""), reverse=True)
            return self.send(200, [strip(i, "") for i in items[:int(q.get("limit", ["20"])[0])]])
        if path == "/Items" and method == "GET":
            return self.send(200, self.items(q))
        m = re.match(r"^/Items/([0-9a-f]{32})$", path)
        if m:
            item = STATE["items"].get(m.group(1))
            return self.send(200, with_user(item)) if item else self.send(404, "")
        m = re.match(r"^/Items/([0-9a-f]{32})/Similar$", path)
        if m:
            me = STATE["items"].get(m.group(1))
            if not me:
                return self.send(404, "")
            items = [i for i in all_items(me["Type"]) if i["Id"] != me["Id"]][:int(q.get("limit", ["10"])[0])]
            return self.send(200, {"Items": [strip(i, "") for i in items], "TotalRecordCount": len(items)})
        m = re.match(r"^/Shows/([0-9a-f]{32})/Seasons$", path)
        if m:
            items = sorted([s for s in all_items("Season") if s["SeriesId"] == m.group(1)], key=lambda s: s["IndexNumber"])
            return self.send(200, {"Items": [strip(i, "") for i in items], "TotalRecordCount": len(items)})
        m = re.match(r"^/Shows/([0-9a-f]{32})/Episodes$", path)
        if m:
            eps = episodes_of(m.group(1))
            season = q.get("seasonId", [None])[0]
            if season:
                eps = [e for e in eps if e["SeasonId"] == season]
            start = q.get("startItemId", [None])[0]
            if start:
                ids = [e["Id"] for e in eps]
                eps = eps[ids.index(start):] if start in ids else []
            if "limit" in q:
                eps = eps[:int(q["limit"][0])]
            return self.send(200, {"Items": [strip(i, "Overview") for i in eps], "TotalRecordCount": len(eps)})
        if path == "/Genres":
            parent = q.get("parentId", [None])[0]
            names = sorted({g for i in all_items() if not parent or i.get("ParentId") == parent for g in i.get("Genres", [])})
            return self.send(200, {"Items": [{"Name": g, "Id": gid(5000 + n), "Type": "Genre"} for n, g in enumerate(names)], "TotalRecordCount": len(names)})
        if path == "/Persons":
            term = q.get("searchTerm", [""])[0].lower()
            people = [strip(i, "") for i in all_items("Person") if term in i["Name"].lower()]
            return self.send(200, {"Items": people, "TotalRecordCount": len(people)})
        m = re.match(r"^/MediaSegments/([0-9a-f]{32})$", path)
        if m:
            items = STATE.get("segments", {}).get(m.group(1), [])
            return self.send(200, {"Items": [dict(s, ItemId=m.group(1), Id=gid(7000 + n)) for n, s in enumerate(items)], "TotalRecordCount": len(items), "StartIndex": 0})

        m = re.match(r"^/User(Played|Favorite)Items/([0-9a-f]{32})$", path)
        if m and method in ("POST", "DELETE"):
            item = STATE["items"].get(m.group(2))
            if not item:
                return self.send(404, "")
            on = method == "POST"
            targets = [item]
            if item["Type"] == "Series" and m.group(1) == "Played":
                targets += episodes_of(item["Id"])
            for t in targets:
                data = STATE["user"][t["Id"]]
                if m.group(1) == "Played":
                    data["Played"] = on
                    data["PlaybackPositionTicks"] = 0 if on else data["PlaybackPositionTicks"]
                    data.pop("PlayedPercentage", None) if on else None
                else:
                    data["IsFavorite"] = on
            return self.send(200, with_user(item)["UserData"])
        m = re.match(r"^/UserItems/([0-9a-f]{32})/UserData$", path)
        if m and method == "POST":
            data = STATE["user"].get(m.group(1))
            if data is None:
                return self.send(404, "")
            if "PlaybackPositionTicks" in body:
                data["PlaybackPositionTicks"] = int(body["PlaybackPositionTicks"])
            return self.send(200, with_user(STATE["items"][m.group(1)])["UserData"])

        m = re.match(r"^/Items/([0-9a-f]{32})/PlaybackInfo$", path)
        if m and method == "POST":
            return self.send(200, self.playback_info(m.group(1), q, body))
        if path in ("/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped") and method == "POST":
            kind = {"/Sessions/Playing": "start", "/Sessions/Playing/Progress": "progress", "/Sessions/Playing/Stopped": "stop"}[path]
            STATE["reports"].append({"kind": kind, "item": body.get("ItemId"), "session": body.get("PlaySessionId"),
                                     "position": body.get("PositionTicks", 0) / TICKS, "paused": body.get("IsPaused"),
                                     "method": body.get("PlayMethod"), "event": body.get("EventName"),
                                     "audio": body.get("AudioStreamIndex"), "subtitle": body.get("SubtitleStreamIndex")})
            if kind == "stop":
                data = STATE["user"].get(body.get("ItemId"))
                item = STATE["items"].get(body.get("ItemId"))
                if data is not None and item:
                    pos = body.get("PositionTicks", 0)
                    if pos >= item.get("RunTimeTicks", 1) * 0.9:
                        data["Played"], data["PlaybackPositionTicks"] = True, 0
                    else:
                        data["PlaybackPositionTicks"] = pos
                    data["LastPlayedDate"] = "2026-10-25T12:00:00.0000000Z"
            return self.send(204, b"")

        # ------------------------------------------------ streams
        m = re.match(r"^/[Vv]ideos/([0-9a-f-]{32,36})/(.+)$", path)
        if m and method == "GET":
            return self.video(m.group(1).replace("-", ""), m.group(2), q)
        return self.send(404, {"detail": "mock: no route for " + method + " " + path})

    def session(self):
        token = secrets.token_hex(16)
        STATE["tokens"][token] = USER_ID
        return {"AccessToken": token, "ServerId": SERVER_ID,
                "User": {"Name": "Daniel", "Id": USER_ID, "Policy": {"IsAdministrator": False}}}

    def items(self, q):
        items = all_items()
        types = q.get("includeItemTypes", [""])[0]
        if types:
            items = [i for i in items if i["Type"] in types.split(",")]
        parent = q.get("parentId", [None])[0]
        recursive = q.get("recursive", ["false"])[0] == "true"
        if parent:
            if parent in STATE.get("children", {}):
                items = [STATE["items"][c] for c in STATE["children"][parent]]
            elif recursive:
                def under(i):
                    p = i.get("ParentId")
                    while p:
                        if p == parent:
                            return True
                        p = STATE["items"].get(p, {}).get("ParentId")
                    return False
                items = [i for i in items if under(i)]
            else:
                items = [i for i in items if i.get("ParentId") == parent]
        elif not recursive:
            items = [i for i in items if i["Type"] == "CollectionFolder"]
        person = q.get("personIds", [None])[0]
        if person:
            items = [i for i in items if any(p.get("Id") == person for p in i.get("People", []))]
        term = q.get("searchTerm", [""])[0].lower()
        if term:
            items = [i for i in items if term in i["Name"].lower()]
        filters = q.get("filters", [""])[0].split(",")
        u = lambda i: with_user(i)["UserData"]
        if "IsPlayed" in filters:
            items = [i for i in items if u(i)["Played"]]
        if "IsUnplayed" in filters:
            items = [i for i in items if not u(i)["Played"]]
        if "IsFavorite" in filters:
            items = [i for i in items if u(i)["IsFavorite"]]
        if "IsResumable" in filters:
            items = [i for i in items if u(i)["PlaybackPositionTicks"] > 0]
        genres = q.get("genres", [""])[0]
        if genres:
            wanted = genres.split("|")
            items = [i for i in items if any(g in i.get("Genres", []) for g in wanted)]
        sort = q.get("sortBy", ["SortName"])[0].split(",")[0]
        key = {"SortName": lambda i: i.get("SortName", i["Name"].lower()), "DateCreated": lambda i: i.get("DateCreated", ""),
               "PremiereDate": lambda i: i.get("PremiereDate", ""), "CommunityRating": lambda i: i.get("CommunityRating", 0),
               "Runtime": lambda i: i.get("RunTimeTicks", 0), "DatePlayed": lambda i: u(i).get("LastPlayedDate", ""),
               "Random": lambda i: i["Id"]}.get(sort, lambda i: i["Name"])
        items.sort(key=key, reverse=q.get("sortOrder", ["Ascending"])[0] == "Descending")
        return page([strip(i, "") for i in items], q)

    def playback_info(self, item_id, q, body):
        item = STATE["items"].get(item_id)
        if not item or "MediaSources" not in item:
            return {"ErrorCode": "NoCompatibleStream", "MediaSources": []}
        session = secrets.token_hex(16)
        token = self.token(q)
        may_convert = body.get("EnableTranscoding", True) is not False and q.get("enableTranscoding", ["true"])[0] != "false"
        STATE["playbackInfo"].append({"item": item_id, "enableTranscoding": may_convert,
                                      "transcodingProfiles": len((body.get("DeviceProfile") or {}).get("TranscodingProfiles") or []),
                                      "subtitle": body.get("SubtitleStreamIndex")})
        sources = []
        cap = body.get("MaxStreamingBitrate") or int(q.get("maxStreamingBitrate", ["0"])[0] or 0)
        for ms in item["MediaSources"]:
            out = json.loads(json.dumps(ms))
            direct = body.get("EnableDirectPlay", True) and not (cap and cap < ms["Bitrate"])
            if not may_convert:
                # Like Jellyfin: nothing to offer but the file, whatever it thinks of it.
                direct = False if body.get("EnableDirectPlay") is False else direct
            out["SupportsDirectPlay"] = direct
            out["SupportsDirectStream"] = direct
            if not direct and may_convert:
                reasons = "ContainerBitrateExceedsLimit" if cap and cap < ms["Bitrate"] else "SubtitleCodecNotSupported"
                dashed = "%s-%s-%s-%s-%s" % (item_id[:8], item_id[8:12], item_id[12:16], item_id[16:20], item_id[20:])
                out["TranscodingUrl"] = ("/videos/%s/master.m3u8?DeviceId=x&MediaSourceId=%s&PlaySessionId=%s&ApiKey=%s&SubtitleMethod=Encode&TranscodeReasons=%s"
                                         % (dashed, ms["Id"], session, token, reasons))
                out["TranscodingSubProtocol"] = "hls"
                out["TranscodingContainer"] = "ts"
            sources.append(out)
        return {"MediaSources": sources, "PlaySessionId": session}

    def video(self, item_id, rest, q):
        if item_id not in STATE["items"]:
            return self.send(404, "")
        if rest == "stream":
            return self.file("test.mp4", "video/mp4")
        if rest == "master.m3u8":
            return self.send(200, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000\nmain.m3u8?MediaSourceId=%s&ApiKey=%s\n" % (item_id, self.token(q)), "application/vnd.apple.mpegurl")
        if rest == "main.m3u8":
            return self.send(200, "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:60\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:60.0,\nhls1/main/0.ts?ApiKey=%s\n#EXT-X-ENDLIST\n" % self.token(q), "application/vnd.apple.mpegurl")
        if rest.startswith("hls1/main/"):
            return self.file("test.ts", "video/mp2t")
        if re.match(r"^[0-9a-f]{32}/Subtitles/\d+/0/Stream\.(vtt|srt)$", rest):
            if rest.endswith("vtt"):
                return self.send(200, "WEBVTT\n\n00:00:00.500 --> 00:00:08.000\nHello from the <i>mock</i>\n\n00:00:08.000 --> 00:00:11.000\nSecond line\n", "text/vtt")
            return self.send(200, "1\n00:00:00,500 --> 00:00:08,000\nHello from the mock\n", "text/plain")
        if re.match(r"^Trickplay/\d+/\d+\.jpg$", rest):
            return self.file("test.png", "image/png") if MEDIA["dir"] else self.send(200, png(1600, 900, (90, 90, 140)), "image/png")
        return self.send(404, "")

    def file(self, name, ctype):
        if not MEDIA["dir"] or not os.path.exists(os.path.join(MEDIA["dir"], name)):
            return self.send(200, b"\x00" * 64, ctype)
        data = open(os.path.join(MEDIA["dir"], name), "rb").read()
        rng = self.headers.get("Range")
        m = re.match(r"bytes=(\d+)-(\d*)", rng or "")
        if m:
            start = int(m.group(1))
            end = int(m.group(2)) if m.group(2) else len(data) - 1
            end = min(end, len(data) - 1)
            return self.send(206, data[start:end + 1], ctype, {"Content-Range": "bytes %d-%d/%d" % (start, end, len(data)), "Accept-Ranges": "bytes"})
        return self.send(200, data, ctype, {"Accept-Ranges": "bytes"})


def seed_big():
    """A library of 300 films, for paging and scrolling."""
    vid = gid(4)
    VIEWS["archive"] = vid
    add({"Id": vid, "Name": "Archive", "Type": "CollectionFolder", "CollectionType": "movies", "IsFolder": True, "ChildCount": 300})
    for n in range(300):
        mid = gid(10000 + n)
        add({"Id": mid, "Name": "Film %03d" % n, "SortName": "film %03d" % n, "Type": "Movie", "MediaType": "Video", "IsFolder": False,
             "ParentId": vid, "ProductionYear": 1950 + n % 70, "RunTimeTicks": 60 * TICKS, "DateCreated": "2025-01-01T00:00:00.0000000Z",
             "ImageTags": {"Primary": "f%d" % n}, "MediaSources": video_source(mid)})


def main():
    port = int(sys.argv[1])
    if "--seed" in sys.argv:
        seed()
    if "--big" in sys.argv:
        seed_big()
    if "--media" in sys.argv:
        MEDIA["dir"] = sys.argv[sys.argv.index("--media") + 1]
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
