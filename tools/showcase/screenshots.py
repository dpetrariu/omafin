#!/usr/bin/env python3
"""Take the README's screenshots: the real Omafin window, off-screen, signed
in to the mock Jellyfin serving the showcase library (the Blender open
movies, fetched by fetch.py). Nothing appears on the desktop and no real
server is involved.

usage: screenshots.py path/to/omafin SHOWCASE_DIR OUT_DIR

Writes OUT_DIR/{home,film,show,library}.webp and copies the showcase
CREDITS.md beside them.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(os.path.dirname(os.path.dirname(HERE)), "tests")
sys.path.insert(0, TESTS)
from backend_e2e import _ping, approve, free_port, wait_for  # noqa: E402
from ui_e2e import Harness  # noqa: E402


def gid(n):
    return "%032x" % (0xA0000000000000000000000000000000 + n)


SPRING, CAMINANDES = gid(5105), gid(5200)


def main():
    binary, showcase, out = (os.path.abspath(a) for a in sys.argv[1:4])
    os.makedirs(out, exist_ok=True)
    port = free_port()
    root = tempfile.mkdtemp(prefix="omafin-shots-")
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(TESTS, "mock_jellyfin.py"), str(port), "--showcase", showcase])
    h = None
    try:
        wait_for("the mock is up", lambda: _ping(port), 10)
        h = Harness(binary, root, os.path.join(root, "shots"))
        os.makedirs(h.shots)
        wait_for("the window is up", lambda: h.ipc("ready") == "yes", 30)
        wait_for("the sign-in page", lambda: h.value("!!hooks.setup.item"), 10)
        h.js(f"hooks.setup.item.address = '127.0.0.1:{port}'")
        h.js("hooks.setup.item.probe()")
        wait_for("a Quick Connect code", lambda: len(h.value("hooks.setup.item.code")) == 6, 10)
        approve(port, h.value("hooks.setup.item.code"))
        wait_for("signed in", lambda: h.value("service.configured") is True, 10)
        wait_for("the home rows", lambda: h.value("app.view() && app.view().home ? app.view().home.resume.length : 0") == 2, 15)

        def shot(name, settle=2.5):
            time.sleep(settle)  # pictures load and fade in
            png = h.shot(name)
            subprocess.run(["magick", png, "-quality", "88", os.path.join(out, name + ".webp")], check=True)

        shot("home")
        h.js(f"app.openItem({{ id: '{SPRING}', type: 'Movie', name: 'Spring' }})")
        wait_for("the film page", lambda: h.value("app.view().item ? app.view().item.name : ''") == "Spring", 10)
        shot("film")
        h.js(f"app.openItem({{ id: '{CAMINANDES}', type: 'Series', name: 'Caminandes' }})")
        wait_for("the show page", lambda: h.value("app.view().episodes.length") == 3, 10)
        shot("show")
        h.nav("go:Movies", 1)
        wait_for("the films", lambda: h.value("app.view().items.length") == 9, 10)
        shot("library")
        errors = h.errors()
        assert not errors, "".join(errors)
        shutil.copy(os.path.join(showcase, "CREDITS.md"), os.path.join(out, "CREDITS.md"))
        print("wrote", out)
    finally:
        if h:
            h.stop()
        mock.terminate()


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main()
