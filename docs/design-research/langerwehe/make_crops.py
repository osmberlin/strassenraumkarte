#!/usr/bin/env python3
"""Side-by-side comparison crops from XYZ tile folders (QGIS / LA / ink).

    python3 docs/design-research/langerwehe/make_crops.py

Reads tiles from tmp/langerwehe/<style>/{z}/{x}/{y}.<ext> (not committed) and writes
JPEG crops to docs/design-research/langerwehe/img/. Each crop is a 2x2 block of tiles
around a WGS84 point, one panel per style, labelled.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
TILES = os.path.join(ROOT, "tmp", "langerwehe")
OUT = os.path.join(os.path.dirname(__file__), "img")

# (name, label, folder under tmp/langerwehe)
STYLES = [
    ("qgis", "QGIS heute", "qgis"),
    ("la", "Landschaftsarchitektur (la)", "la"),
    ("ink", "Tusche (ink)", "ink"),
    ("ink-oblique", "Tusche, frei stehend (ink-oblique)", "ink-oblique"),
]

# (file name, z, lon, lat, title)
CROPS = [
    ("centre_z18", 18, 6.3595, 50.8172, "Ortsmitte Langerwehe, Kirche und Hauptstraße, z18"),
    ("haltepunkt_z18", 18, 6.3501, 50.8177, "Park and Ride und Haltepunkt-Bereich, z18"),
    ("residential_z19", 19, 6.3614, 50.8160, "Schützenstraße / Apollonstraße (Wohnstraßen), z19"),
]


def tile_xy(z, lon, lat):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    r = math.radians(lat)
    y = int((1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * n)
    return x, y


def find_tile(folder, z, x, y):
    for ext in ("webp", "jpg", "png"):
        p = os.path.join(folder, str(z), str(x), f"{y}.{ext}")
        if os.path.exists(p):
            return p
    return None


def stitch(folder, z, x0, y0, size=2):
    canvas = None
    for dy in range(size):
        for dx in range(size):
            p = find_tile(folder, z, x0 + dx, y0 + dy)
            if p is None:
                continue
            im = Image.open(p).convert("RGB")
            if canvas is None:
                canvas = Image.new("RGB", (im.size[0] * size, im.size[1] * size), (237, 237, 237))
            canvas.paste(im, (dx * im.size[0], dy * im.size[1]))
    return canvas


def main():
    os.makedirs(OUT, exist_ok=True)
    font = ImageFont.load_default()
    for name, z, lon, lat, title in CROPS:
        x0, y0 = tile_xy(z, lon, lat)
        panels = []
        for _, label, folder in STYLES:
            path = os.path.join(TILES, folder)
            if not os.path.isdir(path):
                print(f"skip {name}: {folder} missing", file=sys.stderr)
                break
            panels.append((label, stitch(path, z, x0, y0)))
        if len(panels) != len(STYLES):
            continue
        w, h = panels[0][1].size
        header = 28
        out = Image.new("RGB", (w * len(panels) + 8 * (len(panels) - 1), h + header), (255, 255, 255))
        draw = ImageDraw.Draw(out)
        for i, (label, im) in enumerate(panels):
            px = i * (w + 8)
            out.paste(im, (px, header))
            draw.text((px + 6, 8), label, fill=(0, 0, 0), font=font)
        dest = os.path.join(OUT, f"{name}.jpg")
        out.save(dest, "JPEG", quality=82, optimize=True)
        print(f"{dest} {w * len(panels)}x{h + header} {os.path.getsize(dest) // 1024} KB  ({title})")


if __name__ == "__main__":
    main()
