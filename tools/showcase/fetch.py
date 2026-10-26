#!/usr/bin/env python3
"""Fetch the showcase library's pictures from Wikimedia Commons.

Reads library.json beside this file and, into DIR, writes images/ (posters
600x900, backdrops 1280x720, episode stills 640x360, cropped to fill),
library.json (what mock_jellyfin.py --showcase DIR serves) and CREDITS.md
(every picture with its author, licence and source page).

A picture is either a Commons file or a frame of a Commons video at a given
second (Commons renders it). Each one's licence is read from Commons' own
record and anything but CC BY, CC BY-SA, CC0 or public domain is refused, so
the library can be shown anywhere with the credits beside it. Downloads are
cached in DIR/source/; run it again to pick up changes to library.json.

usage: fetch.py DIR
"""
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://commons.wikimedia.org/w/api.php"
UA = {"User-Agent": "omafin-showcase/1 (https://github.com/dpetrariu/omafin)"}
FREE = re.compile(r"^(CC BY(-SA)? [0-9.]+( [a-z]{2})?|CC0|Public domain)$")
SIZES = {"Primary": (600, 900), "Backdrop": (1280, 720), "Episode": (640, 360)}


def commons(title, param):
    q = {"action": "query", "titles": "File:" + title, "prop": "imageinfo", "iiprop": "url|extmetadata",
         "iiurlparam": param, "iiextmetadatafilter": "LicenseShortName|LicenseUrl|Artist", "format": "json", "formatversion": 2}
    url = API + "?" + urllib.parse.urlencode(q)
    page = json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30))["query"]["pages"][0]
    if "imageinfo" not in page:
        sys.exit("not on Commons: " + title)
    info = page["imageinfo"][0]
    meta = {k: v.get("value", "") for k, v in info.get("extmetadata", {}).items()}
    licence = meta.get("LicenseShortName", "")
    if not FREE.match(licence):
        sys.exit("refusing %s: its licence is %r" % (title, licence))
    author = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", meta.get("Artist", ""))).strip()
    return info["thumburl"], {"source": title, "page": info["descriptionurl"], "licence": licence,
                              "licenceUrl": meta.get("LicenseUrl", ""), "author": author}


def picture(spec, size, out_dir, name):
    """Download one picture (cached), crop it to `size` and return its credit."""
    w, h = size
    if "video" in spec:
        title, param = spec["video"], "%dpx-seek=%d" % (max(w, 1280), spec["at"])
    else:
        title, param = spec["file"], "%dpx" % max(w * 2, 1280)
    url, credit = commons(title, param)
    cache = os.path.join(out_dir, "source", re.sub(r"[^A-Za-z0-9]+", "-", title + "-" + param).strip("-").lower())
    if not os.path.exists(cache):
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as resp:
            data = resp.read()
        open(cache + ".part", "wb").write(data)
        os.replace(cache + ".part", cache)
    target = os.path.join(out_dir, "images", name + ".jpg")
    subprocess.run(["magick", cache + "[0]", "-resize", "%dx%d^" % (w, h), "-gravity", spec.get("gravity", "center"),
                    "-extent", "%dx%d" % (w, h), "-strip", "-quality", "85", target], check=True)
    if "at" in spec:
        credit["frameAt"] = spec["at"]
    return credit


def main():
    out = os.path.abspath(sys.argv[1])
    os.makedirs(os.path.join(out, "images"), exist_ok=True)
    library = json.load(open(os.path.join(HERE, "library.json")))
    credits = []

    def fetch(entry, label, episode=False):
        entry["imageFiles"] = {}
        for kind, spec in entry.get("images", {}).items():
            name = entry["key"] + "-" + kind.lower()
            credit = picture(spec, SIZES["Episode" if episode else kind], out, name)
            entry["imageFiles"][kind] = "images/" + name + ".jpg"
            credits.append((label, kind, credit))
            print("ok  %-28s %-8s %s" % (label[:28], kind, credit["licence"]))

    for film in library["films"]:
        fetch(film, film["name"])
    for show in library["shows"]:
        fetch(show, show["name"])
        for n, episode in enumerate(show["episodes"], 1):
            fetch(episode, "%s %d · %s" % (show["name"], n, episode["name"]), episode=True)
    for box in library["collections"]:
        fetch(box, box["name"])
    json.dump(library, open(os.path.join(out, "library.json"), "w"), indent=1, ensure_ascii=False)

    lines = ["# Showcase pictures", "",
             "The showcase library's pictures come from the Blender Foundation's open movies, through Wikimedia Commons. "
             "Each was resized and cropped to fit; frames are stills from the film at the second given.", ""]
    for label, kind, c in credits:
        what = {"Primary": "poster" if "·" not in label else "still", "Backdrop": "backdrop"}.get(kind, kind.lower())
        frame = " (frame at %d s)" % c["frameAt"] if "frameAt" in c else ""
        licence = "[%s](%s)" % (c["licence"], c["licenceUrl"]) if c["licenceUrl"] else c["licence"]
        lines.append("- **%s**, %s: [%s](%s)%s, by %s, %s" % (label, what, c["source"], c["page"], frame, c["author"] or "unknown", licence))
    open(os.path.join(out, "CREDITS.md"), "w").write("\n".join(lines) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not shutil.which("magick"):
        sys.exit("usage: fetch.py DIR (needs ImageMagick)")
    main()
