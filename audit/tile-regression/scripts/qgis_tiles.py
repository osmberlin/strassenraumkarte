#!/usr/bin/env python3
"""
Render exact XYZ tiles with PyQGIS for the tile-regression harness.

Thin harness-side wrapper around render/xyz_tiles.py (the project's tile
renderer). xyz_tiles.py renders a bbox; compares need exact tiles, layer
isolates and the bundled fonts, so this script adds:

  --tiles z/x/y[,z/x/y...]   exact tiles (repeatable), one 1x1 metatile each
  --layers name1,name2       paint only these visible project layers
  --skip-layers name1,name2  paint all visible layers except these (ablation)
  --fonts-dir / --no-fonts   register render/fonts (Open Sans) before painting

Everything else (project loading, Postgres tuning, @mercator_scale, map
settings, gutter handling, tile encoding) is xyz_tiles.py's own code.

Usage:
  python audit/tile-regression/scripts/qgis_tiles.py \
    --project style/strassenraumkarte.qgz --tiles 17/70422/43008 --out /tmp/ref
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[3]
RENDER_DIR = ROOT / "render"
sys.path.insert(0, str(RENDER_DIR))

import xyz_tiles  # noqa: E402  (installs the Qt6 enum aliases via qt_compat)
from qgis.PyQt.QtGui import QFontDatabase  # noqa: E402

DEFAULT_FONTS_DIR = RENDER_DIR / "fonts"


def parse_tiles(args: Sequence[str]) -> List[Tuple[int, int, int]]:
    out: List[Tuple[int, int, int]] = []
    seen = set()
    for arg in args:
        for part in arg.split(","):
            part = part.strip()
            if not part:
                continue
            z, x, y = (int(v) for v in part.split("/"))
            n = 2**z
            if not (0 <= x < n and 0 <= y < n):
                raise ValueError(f"Tile out of range: {part}")
            if (z, x, y) not in seen:
                seen.add((z, x, y))
                out.append((z, x, y))
    if not out:
        raise ValueError("No tiles parsed from --tiles")
    return out


def tile_bounds_wgs84(z: int, x: int, y: int) -> Tuple[float, float, float, float]:
    n = 2**z

    def lat(ty: int) -> float:
        return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * ty / n))))

    return x / n * 360.0 - 180.0, lat(y + 1), (x + 1) / n * 360.0 - 180.0, lat(y)


def register_fonts(fonts_dir: Optional[Path]) -> int:
    if not fonts_dir or not fonts_dir.is_dir():
        return 0
    n = 0
    for font_path in sorted(fonts_dir.iterdir()):
        if font_path.suffix.lower() in {".ttf", ".otf", ".ttc"}:
            if QFontDatabase.addApplicationFont(str(font_path)) != -1:
                n += 1
    return n


def filter_layers(layers: Sequence, names: Sequence[str]) -> list:
    wanted = set(names)
    kept = [layer for layer in layers if layer.name() in wanted]
    missing = sorted(wanted - {layer.name() for layer in kept})
    if missing:
        available = ", ".join(sorted({layer.name() for layer in layers}))
        raise RuntimeError(f"Layer(s) not visible in project: {', '.join(missing)}. Available: {available}")
    return kept


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--project", required=True)
    p.add_argument("--tiles", action="append", required=True, metavar="Z/X/Y")
    p.add_argument("--layers", default=None, help="Comma-separated layer names (default: all visible)")
    p.add_argument("--skip-layers", default=None, help="Comma-separated layer names to leave out")
    p.add_argument("--out", required=True)
    p.add_argument("--format", default="png", choices=["png", "jpg", "jpeg", "webp"])
    p.add_argument("--quality", type=int, default=95)
    p.add_argument("--gutter", type=int, default=1)
    p.add_argument("--dpi", type=int, default=96)
    p.add_argument("--background", default=xyz_tiles.DEFAULT_BACKGROUND)
    p.add_argument("--fonts-dir", default=None, help="Fonts to register (default: render/fonts)")
    p.add_argument("--no-fonts", action="store_true")
    # Accepted for compatibility with older harness calls; single tiles are always 1x1, sequential.
    p.add_argument("--metatile", type=int, default=1, help=argparse.SUPPRESS)
    p.add_argument("--workers", type=int, default=1, help=argparse.SUPPRESS)
    p.add_argument("--jobs", default="1", help=argparse.SUPPRESS)
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    tiles = parse_tiles(args.tiles)
    fmt = xyz_tiles.normalize_tile_format(args.format)
    _, background = xyz_tiles.parse_background_color(args.background)

    bounds = [tile_bounds_wgs84(*t) for t in tiles]
    xmin = min(b[0] for b in bounds)
    ymin = min(b[1] for b in bounds)
    xmax = max(b[2] for b in bounds)
    ymax = max(b[3] for b in bounds)

    # Fonts must be registered after QgsApplication exists but before the project
    # is read (QGIS resolves label font families at load). init_render_context
    # calls install_qt_message_filter() right between the two, so hook in there.
    fonts_dir = None if args.no_fonts else Path(args.fonts_dir) if args.fonts_dir else DEFAULT_FONTS_DIR
    install_filter = xyz_tiles.install_qt_message_filter

    def install_filter_and_fonts() -> None:
        install_filter()
        n_fonts = register_fonts(fonts_dir)
        if n_fonts:
            xyz_tiles.log("INFO", f"Registered {n_fonts} font file(s) from {fonts_dir}")

    xyz_tiles.install_qt_message_filter = install_filter_and_fonts

    ctx = xyz_tiles.init_render_context(
        args.project, xmin, ymin, xmax, ymax, args.dpi, background, log_info=True
    )
    try:
        layers = ctx.layers
        if args.layers:
            names = [n.strip() for n in args.layers.split(",") if n.strip()]
            layers = filter_layers(layers, names)
            xyz_tiles.log("INFO", f"Layer filter: {len(layers)} layer(s): {', '.join(names)}")
        if args.skip_layers:
            skip = {n.strip() for n in args.skip_layers.split(",") if n.strip()}
            before = len(layers)
            layers = [layer for layer in layers if layer.name() not in skip]
            xyz_tiles.log("INFO", f"Skipped {before - len(layers)} layer(s): {', '.join(sorted(skip))}")

        os.makedirs(args.out, exist_ok=True)
        g = args.gutter
        timings = []
        start = time.time()
        for z, x, y in tiles:
            mt = xyz_tiles.MetaTile(z, x, x, y, y, x - g, x + g, y - g, y + g)
            t0 = time.time()
            xyz_tiles.render_metatile(
                ctx.base_settings, layers, mt, args.out, fmt, args.quality, ctx.crs_3857, ctx.background
            )
            ms = round((time.time() - t0) * 1000)
            timings.append({"tile": f"{z}/{x}/{y}", "ms": ms})
            xyz_tiles.log("INFO", f"{z}/{x}/{y} → {ms} ms")
        wall_ms = round((time.time() - start) * 1000)
        Path(args.out, "timing.json").write_text(
            json.dumps(
                {
                    "engine": "qgis",
                    "tiles": len(tiles),
                    "wall_ms": wall_ms,
                    "ms_per_tile": wall_ms / len(tiles),
                    "format": fmt,
                    "layers": args.layers.split(",") if args.layers else None,
                    "gutter": g,
                    "timings": timings,
                },
                indent=2,
            )
            + "\n"
        )
    finally:
        ctx.app.exitQgis()
    return 0


if __name__ == "__main__":
    sys.exit(main())
