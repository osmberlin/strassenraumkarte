#!/usr/bin/env python3
"""Stitch the reference scenes for the design research from rendered XYZ tiles.

Usage:
  python3 make_scenes.py --tiles ../../../render/tiles --out ../scenes

Each scene is a 4×4 block of z19 tiles (1024×1024 px, roughly 190 m wide in Berlin).
"""
import argparse
import os

from PIL import Image

# name: (z, x0, x1, y0, y1, description)
SCENES = {
    "a-herrfurthplatz": (19, 281689, 281692, 172043, 172046, "Round square with church, street trees, perimeter blocks"),
    "b-schillerpromenade": (19, 281691, 281694, 172049, 172052, "Tree-lined promenade with playgrounds, courtyard blocks"),
    "c-hasenheide-edge": (19, 281682, 281685, 172039, 172042, "Park edge: solitary trees, woodland mass, pond, small houses"),
    "d-courtyard-blocks": (19, 281701, 281704, 172044, 172047, "Green courtyards, pedestrian street with playground"),
}


def stitch(root, z, x0, x1, y0, y1):
    im = Image.new("RGB", ((x1 - x0 + 1) * 256, (y1 - y0 + 1) * 256), (237, 237, 237))
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            for ext in ("jpg", "png"):
                p = f"{root}/{z}/{x}/{y}.{ext}"
                if os.path.exists(p):
                    im.paste(Image.open(p).convert("RGB"), ((x - x0) * 256, (y - y0) * 256))
                    break
    return im


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--tiles", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for name, (z, x0, x1, y0, y1, _) in SCENES.items():
        p = os.path.join(a.out, f"{name}.png")
        stitch(a.tiles, z, x0, x1, y0, y1).save(p)
        print(p)
