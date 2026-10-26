#!/usr/bin/env python3
"""Measure where each icon in ui/lib/Icons.js really is, and rewrite the
OPTICAL table there.

Nerd Font icons hang off the space the font reserves for them by different
amounts, and the font's reported bounds do not match what it draws, so the
round buttons centre their icon by a measured table instead. This renders
every icon at 80 px off-screen with Qt, finds the centre of its ink, and
records how far right of the text box's centre and how far above the
baseline that is, as fractions of the font size.

Run it after adding an icon, or if the desktop's monospace font changes:
    python3 tools/icon_optics.py ["Font Family"]
"""
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.join(HERE, "..", "ui", "lib", "Icons.js")
FONT = sys.argv[1] if len(sys.argv) > 1 else "JetBrainsMono Nerd Font"
SIZE, CELL, COLS = 80, 160, 10


def read_png(path):
    data = open(path, "rb").read()
    pos, idat = 8, b""
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, _, ctype = struct.unpack(">IIBB", body[:10])
        if kind == b"IDAT":
            idat += body
        pos += 12 + n
    bpp = {6: 4, 2: 3}[ctype]
    raw = zlib.decompress(idat)
    rows, prev, i = [], bytearray(w * bpp), 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + w * bpp])
        i += 1 + w * bpp
        for x in range(len(line)):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def main():
    source = open(ICONS).read()
    glyphs = source[source.index("var GLYPHS"):source.index("var OPTICAL") if "var OPTICAL" in source else None]
    names = re.findall(r"^  (\w+):", glyphs, re.M)
    work = tempfile.mkdtemp(prefix="omafin-icons-")
    png = os.path.join(work, "icons.png")
    scene = os.path.join(work, "scene.qml")
    open(os.path.join(work, "Icons.js"), "w").write(source)
    open(scene, "w").write(f"""
import QtQuick
import QtQuick.Window
import "Icons.js" as Icons
Window {{
  id: win
  property var names: {json.dumps(names)}
  width: {CELL * COLS}; height: {CELL} * Math.ceil(names.length / {COLS}); visible: true
  Rectangle {{ anchors.fill: parent; color: "black" }}
  Grid {{
    id: grid
    columns: {COLS}
    Repeater {{
      model: win.names
      Item {{
        required property string modelData
        width: {CELL}; height: {CELL}
        Text {{
          text: Icons.glyph(modelData)
          font.family: {json.dumps(FONT)}; font.pixelSize: {SIZE}
          color: "white"
          horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
          Component.onCompleted: console.warn("ICON " + modelData + " " + width + " " + baselineOffset)
        }}
      }}
    }}
  }}
  Timer {{ interval: 700; running: true; onTriggered: grid.grabToImage(function(r) {{ r.saveToFile({json.dumps(png)}); Qt.quit() }}) }}
}}
""")
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_FORCE_STDERR_LOGGING="1")
    out = subprocess.run(["/usr/lib/qt6/bin/qml", scene], env=env, capture_output=True, text=True, timeout=60)
    boxes = {}
    for line in (out.stdout + out.stderr).splitlines():
        m = re.search(r"ICON (\w+) ([\d.]+) ([\d.]+)", line)
        if m:
            boxes[m.group(1)] = (float(m.group(2)), float(m.group(3)))
    w, h, bpp, rows = read_png(png)
    table = {}
    for k, name in enumerate(names):
        cx, cy = (k % COLS) * CELL, (k // COLS) * CELL
        sx = sy = sw = 0.0
        for y in range(cy, cy + CELL):
            r = rows[y]
            for x in range(cx, cx + CELL):
                v = r[x * bpp] / 255
                if v:
                    sx += v * (x - cx + 0.5)
                    sy += v * (y - cy + 0.5)
                    sw += v
        if sw == 0 or name not in boxes:
            continue
        width, base = boxes[name]
        table[name] = (round((sx / sw - width / 2) / SIZE, 4), round((base - sy / sw) / SIZE, 4))
    block = "var OPTICAL = {\n" + ",\n".join(f"  {k}: [{v[0]}, {v[1]}]" for k, v in table.items()) + "\n}"
    if "var OPTICAL" in source:
        source = re.sub(r"var OPTICAL = \{.*?\n\}", lambda _: block, source, flags=re.S)
    open(ICONS, "w").write(source)
    print(f"measured {len(table)} of {len(names)} icons in {FONT}")


if __name__ == "__main__":
    main()
