#!/usr/bin/env python3
"""
Render XYZ map tiles from a QGIS project using a custom metatile loop.

Renders directly in EPSG:3857 (Web Mercator tile grid). Ground-metre symbol
sizes in the project are scaled via the project variable @mercator_scale
(= 1/cos(φ) under EPSG:3857).

Progress is reported after every metatile (zoom, metatile index, tiles, ETA).
Background colour defaults to #ededed (opaque); override with --background.
Independent metatiles render in parallel worker processes (--jobs).
Default --jobs dynamic starts with 1 worker. Until a median for the current
zoom and metatile size exists, another worker may start every 60s if (n+1)
times observed peak PSS fits under 90% RAM. After that, growth uses the
measured median peak memory per metatile.
At ≥95% RAM, or while swap keeps growing, the youngest extra worker is killed
and its metatile is re-queued; the job cap ratchets down. The last worker is
never killed — instead its metatile core is halved (down to 2x2).
Workers recycle every 20 metatiles, and a worker lost to a crash or the OOM
killer has its metatile re-queued.
"""

from __future__ import annotations

import argparse
import atexit
import ctypes
import math
import multiprocessing
import os
import queue
import re
import statistics
import subprocess
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
# GDAL defaults its block cache to ~5 % of RAM *per process*; with several
# workers that alone can reserve many GiB. Must be set before GDAL loads.
os.environ.setdefault("GDAL_CACHEMAX", "256")
os.environ.setdefault("QT_IMAGE_ALLOCATION_LIMIT", "512")

from qgis.core import (  # noqa: E402
    Qgis,
    QgsApplication,
    QgsCoordinateReferenceSystem,
    QgsDataSourceUri,
    QgsExpressionContext,
    QgsExpressionContextUtils,
    QgsGeometryGeneratorSymbolLayer,
    QgsMapRendererCustomPainterJob,
    QgsMapSettings,
    QgsProject,
    QgsRectangle,
)
from qgis.PyQt.QtCore import QSize, qInstallMessageHandler  # noqa: E402
from qgis.PyQt.QtGui import QColor, QImage, QPainter  # noqa: E402

ORIGIN_SHIFT = 20037508.342789244
TILE_SIZE_PX = 256
DEFAULT_BACKGROUND = "#ededed"

# Qt stderr spam when painting onto a null QImage (engine == 0, type 3 = Image).
# Empty map data does *not* cause this; QGIS may still emit it for failed internal
# symbol/label buffers while the main metatile image is fine. Real allocation
# failure of the metatile buffer is checked via QImage.isNull() instead.
_QPAINTER_NOISE_RE = re.compile(
    r"^QPainter::("
    r"begin: Paint device returned engine == 0"
    r"|setRenderHint: Painter must be active"
    r"|translate: Painter not active"
    r"|end: Painter not active"
    r"|.+: Painter not active"
    r")"
)

DB_NAME = os.environ.get("DB_NAME", "strassenraumkarte")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5433")


@dataclass(frozen=True)
class TileRange:
    x0: int
    x1: int
    y0: int
    y1: int

    @property
    def count(self) -> int:
        return max(0, (self.x1 - self.x0 + 1) * (self.y1 - self.y0 + 1))


@dataclass(frozen=True)
class MetaTile:
    """Core tiles (x0..x1, y0..y1) are written; rx*/ry* include gutter for render."""

    z: int
    x0: int
    x1: int
    y0: int
    y1: int
    rx0: int
    rx1: int
    ry0: int
    ry1: int

    @property
    def width_tiles(self) -> int:
        return self.x1 - self.x0 + 1

    @property
    def height_tiles(self) -> int:
        return self.y1 - self.y0 + 1

    @property
    def tile_count(self) -> int:
        return self.width_tiles * self.height_tiles

    @property
    def render_width_tiles(self) -> int:
        return self.rx1 - self.rx0 + 1

    @property
    def render_height_tiles(self) -> int:
        return self.ry1 - self.ry0 + 1


def log(level: str, msg: str) -> None:
    finish_progress_line()
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  [{level}] {msg}", flush=True)


def _qt_message_handler(mode, context, message: str) -> None:  # noqa: ARG001
    """Drop cascading QPainter noise; keep other Qt/QGIS messages on stderr."""
    if _QPAINTER_NOISE_RE.match(message):
        return
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


def install_qt_message_filter() -> None:
    """Suppress QPainter cascade warnings that do not indicate empty tile data."""
    qInstallMessageHandler(_qt_message_handler)


def parse_background_color(value: str) -> Tuple[str, QColor]:
    """Parse '#rrggbb' / 'rrggbb' → (normalised hex, QColor)."""
    raw = value.strip()
    if raw.startswith("#"):
        raw = raw[1:]
    if not re.fullmatch(r"[0-9A-Fa-f]{6}", raw):
        raise ValueError(f"Invalid background colour (expected #rrggbb): {value}")
    hex_str = f"#{raw.lower()}"
    r, g, b = int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16)
    return hex_str, QColor(r, g, b)


def format_duration(secs: float) -> str:
    secs_i = max(0, int(secs))
    h, rem = divmod(secs_i, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def parse_extent(extent: str) -> Tuple[float, float, float, float]:
    """Parse 'xmin,ymin,xmax,ymax [EPSG:4326]' → (xmin, ymin, xmax, ymax)."""
    m = re.match(
        r"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*"
        r"(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)",
        extent,
    )
    if not m:
        raise ValueError(f"Invalid extent: {extent}")
    xmin, ymin, xmax, ymax = map(float, m.groups())
    if xmin > xmax:
        xmin, xmax = xmax, xmin
    if ymin > ymax:
        ymin, ymax = ymax, ymin
    return xmin, ymin, xmax, ymax


def clamp_lat(lat: float) -> float:
    return max(min(lat, 85.05112878), -85.05112878)


def mercator_scale_from_lat(lat: float) -> float:
    """Web Mercator ground-metre → map-unit factor at geodetic latitude φ."""
    lat = clamp_lat(lat)
    # Slightly tighter than Web Mercator limit for cos stability.
    lat = max(min(lat, 85.0), -85.0)
    return 1.0 / math.cos(math.radians(lat))


def scale_factor_from_processing_crs() -> Optional[Tuple[float, float, str]]:
    """Return (scale_factor, latitude, source) from public._processing_crs if present."""
    env = os.environ.copy()
    if "PGPASSFILE" not in env and os.path.isfile(os.path.expanduser("~/.pgpass")):
        env["PGPASSFILE"] = os.path.expanduser("~/.pgpass")
    sql = (
        "SELECT scale_factor::text, COALESCE(latitude::text, ''), source "
        "FROM public._processing_crs LIMIT 1;"
    )
    try:
        raw = subprocess.check_output(
            [
                "psql",
                "-U", DB_USER,
                "-h", DB_HOST,
                "-p", DB_PORT,
                "-d", DB_NAME,
                "-At",
                "-F", "\t",
                "-c", sql,
            ],
            env=env,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    if not raw:
        return None
    parts = raw.split("\t")
    if len(parts) < 1:
        return None
    try:
        scale = float(parts[0])
    except ValueError:
        return None
    lat = float(parts[1]) if len(parts) > 1 and parts[1] else float("nan")
    source = parts[2] if len(parts) > 2 else "db"
    return scale, lat, source


def resolve_mercator_scale(
    project: QgsProject,
    xmin: float,
    ymin: float,
    xmax: float,
    ymax: float,
) -> Tuple[float, str]:
    """
    Resolve @mercator_scale for this render run.

    Returns (scale, description_for_log).
    """
    project_crs = project.crs()
    if not project_crs.isValid() or project_crs.authid() != "EPSG:3857":
        return 1.0, f"CRS {project_crs.authid() or 'invalid'} → scale 1"

    # 1) Mid-latitude of render extent (WGS84 bbox from --extent / --bbox)
    mid_lat = (ymin + ymax) / 2.0
    if math.isfinite(mid_lat) and abs(mid_lat) <= 90:
        scale = mercator_scale_from_lat(mid_lat)
        return scale, f"extent mid-lat {mid_lat:.5f} → scale {scale:.6f}"

    # 2) Processing table
    db = scale_factor_from_processing_crs()
    if db is not None:
        scale, lat, source = db
        lat_s = f"{lat:.5f}" if math.isfinite(lat) else "?"
        return scale, f"_processing_crs ({source}, lat {lat_s}) → scale {scale:.6f}"

    return 1.0, "fallback → scale 1"


def lon_to_tile_x(lon: float, z: int) -> int:
    n = 2**z
    x = int((lon + 180.0) / 360.0 * n)
    return min(max(x, 0), n - 1)


def lat_to_tile_y(lat: float, z: int) -> int:
    lat = clamp_lat(lat)
    lat_rad = math.radians(lat)
    n = 2**z
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return min(max(y, 0), n - 1)


def tile_range_for_bbox(xmin: float, ymin: float, xmax: float, ymax: float, z: int) -> TileRange:
    x0 = lon_to_tile_x(xmin, z)
    x1 = lon_to_tile_x(xmax, z)
    y0 = lat_to_tile_y(ymax, z)  # north → smaller y
    y1 = lat_to_tile_y(ymin, z)
    if x1 < x0:
        x0, x1 = x1, x0
    if y1 < y0:
        y0, y1 = y1, y0
    return TileRange(x0, x1, y0, y1)


# Keeps a bbox edge that lands on a tile boundary inside the strict range
# when float rounding nudges it a fraction past the integer.
_TILE_EDGE_EPS = 1e-9


def _tile_x_continuous(lon: float, z: int) -> float:
    return (lon + 180.0) / 360.0 * (2**z)


def _tile_y_continuous(lat: float, z: int) -> float:
    lat = clamp_lat(lat)
    lat_rad = math.radians(lat)
    return (1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (2**z)


def _empty_tile_range() -> TileRange:
    return TileRange(0, -1, 0, -1)


def tile_range_inside_bbox(xmin: float, ymin: float, xmax: float, ymax: float, z: int) -> TileRange:
    """Tiles whose full extent lies inside the bbox.

    A tile that only overlaps the bbox is left out, so its empty outer strip
    is not written over an existing tile from a larger render. An edge that
    sits exactly on a tile boundary still counts as inside.
    """
    n = 2**z
    eps = _TILE_EDGE_EPS
    x0 = math.ceil(_tile_x_continuous(xmin, z) - eps)
    x1 = math.floor(_tile_x_continuous(xmax, z) + eps) - 1
    # y grows southward: north edge of tile y is continuous y, south edge is y+1.
    y0 = math.ceil(_tile_y_continuous(ymax, z) - eps)
    y1 = math.floor(_tile_y_continuous(ymin, z) + eps) - 1
    x0 = max(0, x0)
    y0 = max(0, y0)
    x1 = min(n - 1, x1)
    y1 = min(n - 1, y1)
    if x0 > x1 or y0 > y1:
        return _empty_tile_range()
    return TileRange(x0, x1, y0, y1)


def tile_bounds_3857(x: int, y: int, z: int) -> QgsRectangle:
    n = 2**z
    tile_m = (2 * ORIGIN_SHIFT) / n
    minx = -ORIGIN_SHIFT + x * tile_m
    maxx = -ORIGIN_SHIFT + (x + 1) * tile_m
    maxy = ORIGIN_SHIFT - y * tile_m
    miny = ORIGIN_SHIFT - (y + 1) * tile_m
    return QgsRectangle(minx, miny, maxx, maxy)


def metatile_extent_3857(mt: MetaTile) -> QgsRectangle:
    """Extent of the render area (core + gutter)."""
    nw = tile_bounds_3857(mt.rx0, mt.ry0, mt.z)
    se = tile_bounds_3857(mt.rx1, mt.ry1, mt.z)
    return QgsRectangle(nw.xMinimum(), se.yMinimum(), se.xMaximum(), nw.yMaximum())


def hilbert_index(x: int, y: int, order: int) -> int:
    """Distance along a Hilbert curve. x and y must lie in 0 .. 2^order - 1."""
    d = 0
    n = 1 << order
    s = n >> 1
    while s:
        rx = 1 if (x & s) else 0
        ry = 1 if (y & s) else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                x = n - 1 - x
                y = n - 1 - y
            x, y = y, x
        s >>= 1
    return d


def hilbert_sort_metatiles(metas: Sequence[MetaTile]) -> List[MetaTile]:
    """Order metatiles along a Hilbert curve within each zoom.

    Nearby metatiles stay together, which keeps Postgres and symbol caches warm.
    Zoom order itself is unchanged.
    """
    by_zoom: Dict[int, List[MetaTile]] = {}
    for mt in metas:
        by_zoom.setdefault(mt.z, []).append(mt)
    ordered: List[MetaTile] = []
    for z in sorted(by_zoom):
        group = by_zoom[z]
        group.sort(key=lambda mt, z=z: hilbert_index(mt.x0, mt.y0, z))
        ordered.extend(group)
    return ordered


def iter_metatiles(tr: TileRange, z: int, metatile: int, gutter: int) -> List[MetaTile]:
    """Build metatile cores on the grid; expand each by gutter for rendering only."""
    tiles: List[MetaTile] = []
    n = 2**z
    max_xy = n - 1
    gx0 = (tr.x0 // metatile) * metatile
    gy0 = (tr.y0 // metatile) * metatile
    for gy in range(gy0, tr.y1 + 1, metatile):
        for gx in range(gx0, tr.x1 + 1, metatile):
            x0 = max(tr.x0, gx)
            x1 = min(tr.x1, gx + metatile - 1)
            y0 = max(tr.y0, gy)
            y1 = min(tr.y1, gy + metatile - 1)
            if x0 > x1 or y0 > y1:
                continue
            rx0 = max(0, x0 - gutter)
            rx1 = min(max_xy, x1 + gutter)
            ry0 = max(0, y0 - gutter)
            ry1 = min(max_xy, y1 + gutter)
            tiles.append(MetaTile(z, x0, x1, y0, y1, rx0, rx1, ry0, ry1))
    return tiles


def split_metatile(mt: MetaTile, size_cap: int, gutter: int) -> List[MetaTile]:
    """Cut a metatile core into blocks of at most size_cap tiles per side."""
    if size_cap >= max(mt.width_tiles, mt.height_tiles):
        return [mt]
    max_xy = 2**mt.z - 1
    parts: List[MetaTile] = []
    for y0 in range(mt.y0, mt.y1 + 1, size_cap):
        y1 = min(mt.y1, y0 + size_cap - 1)
        for x0 in range(mt.x0, mt.x1 + 1, size_cap):
            x1 = min(mt.x1, x0 + size_cap - 1)
            parts.append(
                MetaTile(
                    mt.z,
                    x0,
                    x1,
                    y0,
                    y1,
                    max(0, x0 - gutter),
                    min(max_xy, x1 + gutter),
                    max(0, y0 - gutter),
                    min(max_xy, y1 + gutter),
                )
            )
    return parts


def postgres_render_uri(source: str) -> Optional[str]:
    """Rewrite a Postgres provider URI for rendering.

    estimatedmetadata skips a full-table extent scan on connect.
    checkPrimaryKeyUnicity=0 skips the uniqueness scan QGIS otherwise runs
    because the project asks for key='tid'. The .qgz file is not modified.
    """
    uri = QgsDataSourceUri(source)
    if not uri.table():
        return None
    # The project file pins one database. DB_NAME (env) is the one this run
    # should read, so a second database can be profiled without editing the .qgz.
    if DB_NAME:
        uri.setDatabase(DB_NAME)
    uri.setUseEstimatedMetadata(True)
    # setParam appends a second copy; drop the project value first.
    uri.removeParam("checkPrimaryKeyUnicity")
    uri.setParam("checkPrimaryKeyUnicity", "0")
    return uri.uri(False)


# Shapeburst rasterises a polygon's bounding box. A dissolved water body can be
# tens of kilometres across, so one z18 tile was spending ~11 min and ~21 GiB
# on that image. Clipping to the map extent plus the gradient's reach keeps
# the raster tile-sized. The margin is outside the painted extent, so the
# artificial cut does not show: 150 mm of screen distance covers the widest
# shapeburst in the project (100 mm) at any zoom, plus 20 m for map-unit rims.
_SHAPEBURST_CLIP = (
    "intersection($geometry, buffer(@map_extent, 150 * @map_scale / 1000 + 20))"
)


def _symbol_has_shapeburst(symbol) -> bool:
    if symbol is None:
        return False
    for i in range(symbol.symbolLayerCount()):
        layer = symbol.symbolLayer(i)
        if layer is not None and layer.layerType() == "ShapeburstFill":
            return True
        sub = layer.subSymbol() if layer is not None else None
        if sub is not None and _symbol_has_shapeburst(sub):
            return True
    return False


def _clip_shapeburst_symbol(symbol):
    """Draw this symbol on the map extent only, so shapeburst stays local."""
    gen = QgsGeometryGeneratorSymbolLayer.create({"SymbolType": "Fill"})
    if gen is None:
        return symbol
    gen.setSymbolType(Qgis.SymbolType.Fill)
    gen.setGeometryExpression(_SHAPEBURST_CLIP)
    if not gen.setSubSymbol(symbol.clone()):
        return symbol
    wrapped = symbol.clone()
    while wrapped.symbolLayerCount():
        wrapped.deleteSymbolLayer(0)
    wrapped.appendSymbolLayer(gen)
    return wrapped


def _clip_rule_symbols(rule) -> int:
    n = 0
    symbol = rule.symbol()
    if symbol is not None and _symbol_has_shapeburst(symbol):
        rule.setSymbol(_clip_shapeburst_symbol(symbol))
        n += 1
    children = rule.children() if hasattr(rule, "children") else None
    if not children and hasattr(rule, "childrenCount") and hasattr(rule, "child"):
        children = [rule.child(i) for i in range(rule.childrenCount())]
    for child in children or []:
        n += _clip_rule_symbols(child)
    return n


def _replace_categories(renderer, categories, clip_index: set) -> int:
    renderer.deleteAllCategories()
    n = 0
    for i, cat in enumerate(categories):
        if i in clip_index and cat.symbol() is not None:
            cat.setSymbol(_clip_shapeburst_symbol(cat.symbol()))
            n += 1
        renderer.addCategory(cat)
    return n


def localize_shapeburst_layers(layers: Sequence) -> int:
    """Clip shapeburst symbols to the current map extent. Returns symbol count."""
    clipped = 0
    for layer in layers:
        renderer = layer.renderer() if hasattr(layer, "renderer") else None
        if renderer is None:
            continue
        if hasattr(renderer, "rootRule"):
            clipped += _clip_rule_symbols(renderer.rootRule())
            continue
        if hasattr(renderer, "categories") and hasattr(renderer, "deleteAllCategories"):
            categories = list(renderer.categories())
            hit = {
                i
                for i, cat in enumerate(categories)
                if _symbol_has_shapeburst(cat.symbol())
            }
            if hit:
                clipped += _replace_categories(renderer, categories, hit)
            continue
        if hasattr(renderer, "symbol") and hasattr(renderer, "setSymbol"):
            symbol = renderer.symbol()
            if _symbol_has_shapeburst(symbol):
                renderer.setSymbol(_clip_shapeburst_symbol(symbol))
                clipped += 1
    return clipped


def tune_postgres_layer(layer) -> bool:
    """Apply postgres_render_uri to one layer. Returns True when rewritten."""
    if layer.providerType() != "postgres":
        return False
    updated = postgres_render_uri(layer.source())
    if not updated or updated == layer.source():
        return False
    layer.setDataSource(updated, layer.name(), "postgres", False)
    return True


def collect_visible_layers(project: QgsProject) -> List:
    """Return visible, valid layers for QgsMapSettings (first = topmost)."""
    root = project.layerTreeRoot()
    layers = []
    for layer in root.layerOrder():
        if layer is None or not layer.isValid():
            continue
        node = root.findLayer(layer.id())
        if node is None or not node.isVisible():
            continue
        layers.append(layer)
    return layers


_progress_line_width = 0


def print_progress(
    *,
    zoom: int,
    zmax: int,
    meta_done: int,
    meta_total: int,
    done_tiles: int,
    total_tiles: int,
    elapsed: float,
    jobs: int,
) -> None:
    """Overwrite a single progress line via carriage return."""
    global _progress_line_width
    if total_tiles:
        pct = min(100.0, max(0.0, done_tiles * 100.0 / total_tiles))
    else:
        pct = 100.0
    if done_tiles > 0 and done_tiles < total_tiles and elapsed > 0:
        remaining = format_duration(elapsed * (total_tiles - done_tiles) / done_tiles)
    elif done_tiles >= total_tiles:
        remaining = "0s"
    else:
        remaining = "--"
    info = mem_bytes()
    if info is not None and info[0] > 0:
        used_gb = (info[0] - info[1]) / (1024 ** 3)
        ram_s = f"RAM={used_gb:.1f}GB"
    else:
        ram_s = "RAM=?"
    line = (
        f"{pct:5.1f}%  zoom {zoom}/{zmax}  "
        f"metatiles {meta_done}/{meta_total}  "
        f"tiles {done_tiles}/{total_tiles}  "
        f"jobs={jobs}  "
        f"{ram_s}  "
        f"elapsed {format_duration(elapsed)}  "
        f"remaining {remaining}"
    )
    pad = max(0, _progress_line_width - len(line))
    _progress_line_width = max(_progress_line_width, len(line))
    print(f"\r{line}{' ' * pad}", end="", flush=True)


def finish_progress_line() -> None:
    """End the in-place progress line before normal log output."""
    global _progress_line_width
    if _progress_line_width:
        print(flush=True)
        _progress_line_width = 0


def normalize_tile_format(fmt: str) -> str:
    """Map CLI format aliases to the on-disk extension (webp, jpg, png)."""
    fmt = fmt.lower()
    if fmt == "jpeg":
        return "jpg"
    return fmt


def save_tile_image(
    tile: QImage,
    path: str,
    fmt: str,
    quality: int,
    background: QColor,
) -> None:
    """
    Write one tile to disk.

    JPEG and lossy WebP have no useful alpha here: composite the premultiplied
    ARGB buffer onto the opaque background before encoding. Saving
    ARGB32_Premultiplied directly as JPEG/WebP drops alpha incorrectly and can
    yield flat gray tiles.
    """
    if fmt in ("jpg", "webp"):
        opaque = QImage(tile.size(), QImage.Format_RGB888)
        opaque.fill(background.rgb())
        painter = QPainter(opaque)
        painter.drawImage(0, 0, tile)
        painter.end()
        qt_fmt = "WEBP" if fmt == "webp" else "JPEG"
        ok = opaque.save(path, qt_fmt, quality)
    else:
        ok = tile.save(path, "PNG")
    if not ok:
        hint = ""
        if fmt == "webp":
            hint = " (Qt WebP plugin missing? install distro qt imageformats)"
        raise RuntimeError(f"Failed to save tile {path} as {fmt}{hint}")


def render_metatile(
    settings_template: QgsMapSettings,
    layers: Sequence,
    mt: MetaTile,
    out_dir: str,
    fmt: str,
    quality: int,
    crs_3857: QgsCoordinateReferenceSystem,
    background: QColor,
    *,
    before_start=None,
    after_finish=None,
    wait_events: bool = False,
) -> int:
    extent_3857 = metatile_extent_3857(mt)
    width_px = mt.render_width_tiles * TILE_SIZE_PX
    height_px = mt.render_height_tiles * TILE_SIZE_PX

    settings = QgsMapSettings(settings_template)
    settings.setDestinationCrs(crs_3857)
    settings.setLayers(list(layers))
    settings.setExtent(extent_3857)
    settings.setOutputSize(QSize(width_px, height_px))
    settings.setBackgroundColor(background)
    # fromMapSettings copies expressionContext() as-is and does not add
    # mapSettingsScope. Without it @map_scale is NULL → label FontOpacity
    # CASE WHEN @map_scale < 2000 … always hits ELSE (full opacity).
    context = QgsExpressionContext(settings.expressionContext())
    context.appendScope(QgsExpressionContextUtils.mapSettingsScope(settings))
    settings.setExpressionContext(context)

    image = QImage(QSize(width_px, height_px), QImage.Format_ARGB32_Premultiplied)
    if image.isNull():
        raise RuntimeError(
            f"Failed to allocate render buffer {width_px}×{height_px} px for "
            f"z{mt.z} x{mt.rx0}-{mt.rx1} y{mt.ry0}-{mt.ry1} "
            f"(out of memory?). Try a smaller --metatile."
        )
    image.fill(background)
    painter = QPainter()
    if not painter.begin(image):
        raise RuntimeError(
            f"QPainter.begin failed for {width_px}×{height_px} px "
            f"(z{mt.z} x{mt.rx0}-{mt.rx1} y{mt.ry0}-{mt.ry1})."
        )
    painter.setRenderHint(QPainter.Antialiasing, True)
    job = QgsMapRendererCustomPainterJob(settings, painter)
    if before_start is not None:
        before_start(job)
    job.start()
    if wait_events:
        # Queued layerRendered signals are only delivered if the event loop runs.
        job.waitForFinishedWithEventLoop()
    else:
        job.waitForFinished()
    if after_finish is not None:
        after_finish(job)
    painter.end()

    # Write core tiles only; gutter is discarded after render.
    written = 0
    for ty in range(mt.y0, mt.y1 + 1):
        for tx in range(mt.x0, mt.x1 + 1):
            px = (tx - mt.rx0) * TILE_SIZE_PX
            py = (ty - mt.ry0) * TILE_SIZE_PX
            tile = image.copy(px, py, TILE_SIZE_PX, TILE_SIZE_PX)
            tile_dir = os.path.join(out_dir, str(mt.z), str(tx))
            os.makedirs(tile_dir, exist_ok=True)
            path = os.path.join(tile_dir, f"{ty}.{fmt}")
            save_tile_image(tile, path, fmt, quality, background)
            written += 1
    return written


EMERGENCY_USED = 0.95
GROW_HEADROOM = 0.90
MEM_SAMPLE_S = 5.0
EMERGENCY_COOLDOWN_S = 5.0
# Successful metatiles at the reduced cap before allowing +1 worker again.
CEILING_RECOVERY_METAS = 2
# ...and this long without any pressure, so caps do not flap while RAM is tight.
RECOVERY_QUIET_S = 30.0
PSS_WINDOW = 10
PSS_MIN_SAMPLES = 3
PSS_GROW_MARGIN = 1.2
BOOTSTRAP_S = 60.0
DYNAMIC_JOBS_FALLBACK = 2
# Swap growth means we are already past physical RAM, even if MemAvailable
# still looks fine (MemAvailable does not account for swap).
SWAP_ALARM_BYTES = 256 * 1024 * 1024
SWAP_WINDOW_S = 60.0
# Keep samples longer than the plateau we judge, so trimming cannot make the
# oldest sample younger than the stable period (that made relaxation impossible).
SWAP_BASELINE_WINDOW_S = 360.0
SWAP_BASELINE_STABLE_S = 300.0
# Ignore page-sized jitter: only a clear climb over the last window counts.
SWAP_GROW_STEP_BYTES = SWAP_ALARM_BYTES // 4
# Smallest metatile core the dynamic cap may fall back to. Gutter overhead
# grows as cores shrink: 1.6x at 8, 2.3x at 4, 4x at 2 (with gutter 1).
MIN_METATILE = 2
# Recycle workers to bound QGIS/GDAL cache growth and heap fragmentation.
# Profiling showed the multi-GiB spikes were one shapeburst raster per metatile
# (clipped in localize_shapeburst_layers), not a cache that grew across tiles,
# so this bound stays at 20.
WORKER_MAX_METAS = 20
WORKER_OOM_SCORE_ADJ = 700
# Wait this long before treating an exited worker as crashed, so results
# still travelling through the queue can be accounted for first.
DEAD_GRACE_S = 2.0
# With no worker running we are not the cause of the pressure, so shrink the
# work and eventually start one anyway instead of stalling forever.
NO_WORKER_SHRINK_S = 30.0
NO_WORKER_FORCE_S = 120.0
# Last resort: bail out instead of spinning if all bookkeeping is empty but
# tiles are still missing.
STUCK_TIMEOUT_S = 120.0
_WORKER_SENTINEL = None


def parse_jobs_arg(value: str):
    """Return 'dynamic' or an int >= 1."""
    raw = str(value).strip().lower()
    if raw == "dynamic":
        return "dynamic"
    try:
        n = int(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "use 'dynamic' or an integer >= 1"
        ) from exc
    if n < 1:
        raise argparse.ArgumentTypeError("use 'dynamic' or an integer >= 1")
    return n


def _meminfo_kb(text: str, key: str) -> Optional[int]:
    for line in text.splitlines():
        if not line.startswith(key):
            continue
        if len(line) > len(key) and line[len(key)] not in " \t":
            continue
        parts = line.split()
        if len(parts) >= 2:
            try:
                return int(parts[1])
            except ValueError:
                return None
    return None


def _swap_bytes_darwin() -> Tuple[int, int]:
    """(swap_total, swap_free) from sysctl vm.swapusage; zeros if unavailable."""
    try:
        out = subprocess.check_output(
            ["sysctl", "-n", "vm.swapusage"], text=True
        )
    except Exception:  # noqa: BLE001
        return 0, 0
    units = {"b": 1, "k": 1024, "m": 1024**2, "g": 1024**3, "t": 1024**4}

    def field(name: str) -> int:
        m = re.search(rf"{name}\s*=\s*([\d.]+)([BKMGT])", out, re.I)
        if not m:
            return 0
        return int(float(m.group(1)) * units[m.group(2).lower()])

    return field("total"), field("free")


def mem_bytes() -> Optional[Tuple[int, int, int, int]]:
    """(total, available, swap_total, swap_free) bytes, or None if unmeasurable."""
    plat = sys.platform
    try:
        if plat.startswith("linux"):
            with open("/proc/meminfo", encoding="utf-8") as fh:
                text = fh.read()
            total_kb = _meminfo_kb(text, "MemTotal:")
            avail_kb = _meminfo_kb(text, "MemAvailable:")
            swap_total_kb = _meminfo_kb(text, "SwapTotal:") or 0
            swap_free_kb = _meminfo_kb(text, "SwapFree:") or 0
            if total_kb and avail_kb is not None:
                return (
                    total_kb * 1024,
                    avail_kb * 1024,
                    swap_total_kb * 1024,
                    swap_free_kb * 1024,
                )
            return None
        if plat == "darwin":
            total_b = int(
                subprocess.check_output(
                    ["sysctl", "-n", "hw.memsize"], text=True
                ).strip()
            )
            vm = subprocess.check_output(["vm_stat"], text=True)
            page_size = 4096
            pages = {}
            for line in vm.splitlines():
                lower = line.lower()
                if "page size of" in lower:
                    m = re.search(r"(\d+)\s+bytes", line, re.I)
                    if m:
                        page_size = int(m.group(1))
                    continue
                if ":" not in line:
                    continue
                key, rest = line.split(":", 1)
                num = rest.strip().rstrip(".")
                num = num.replace(",", "").replace(".", "")
                try:
                    pages[key.strip().lower()] = int(num)
                except ValueError:
                    continue
            free = (
                pages.get("pages free", 0)
                + pages.get("pages inactive", 0)
                + pages.get("pages speculative", 0)
                + pages.get("pages purgeable", 0)
            )
            avail = free * page_size
            if total_b > 0:
                swap_total, swap_free = _swap_bytes_darwin()
                return total_b, avail, swap_total, swap_free
            return None
        if plat.startswith("win"):
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            stat = MEMORYSTATUSEX()
            stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
                return None
            total = int(stat.ullTotalPhys)
            avail = int(stat.ullAvailPhys)
            # Commit charge minus physical is the pagefile part.
            swap_total = max(0, int(stat.ullTotalPageFile) - total)
            swap_free = min(swap_total, max(0, int(stat.ullAvailPageFile) - avail))
            return total, avail, swap_total, swap_free
    except Exception:  # noqa: BLE001
        return None
    return None


def mem_used_fraction() -> Optional[float]:
    """Return 1 - available/total, or None if RAM cannot be measured."""
    info = mem_bytes()
    if info is None:
        return None
    total, avail = info[0], info[1]
    if total <= 0:
        return None
    return max(0.0, min(1.0, 1.0 - avail / total))


def process_pss_bytes(pid: int) -> Optional[int]:
    """Peak-relevant process weight: PSS on Linux, RSS elsewhere."""
    if pid <= 0:
        return None
    plat = sys.platform
    try:
        if plat.startswith("linux"):
            try:
                with open(f"/proc/{pid}/smaps_rollup", encoding="utf-8") as fh:
                    text = fh.read()
                pss_kb = _meminfo_kb(text, "Pss:")
                if pss_kb is not None:
                    return pss_kb * 1024
            except FileNotFoundError:
                pass
            with open(f"/proc/{pid}/status", encoding="utf-8") as fh:
                text = fh.read()
            rss_kb = _meminfo_kb(text, "VmRSS:")
            if rss_kb is not None:
                return rss_kb * 1024
            return None
        if plat == "darwin":
            out = subprocess.check_output(
                ["ps", "-o", "rss=", "-p", str(pid)], text=True
            ).strip()
            if not out:
                return None
            return int(out.split()[0]) * 1024
        if plat.startswith("win"):
            PROCESS_QUERY_INFORMATION = 0x0400
            PROCESS_VM_READ = 0x0010
            handle = ctypes.windll.kernel32.OpenProcess(
                PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid
            )
            if not handle:
                return None
            try:

                class PROCESS_MEMORY_COUNTERS_EX(ctypes.Structure):
                    _fields_ = [
                        ("cb", ctypes.c_ulong),
                        ("PageFaultCount", ctypes.c_ulong),
                        ("PeakWorkingSetSize", ctypes.c_size_t),
                        ("WorkingSetSize", ctypes.c_size_t),
                        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                        ("PagefileUsage", ctypes.c_size_t),
                        ("PeakPagefileUsage", ctypes.c_size_t),
                        ("PrivateUsage", ctypes.c_size_t),
                    ]

                counters = PROCESS_MEMORY_COUNTERS_EX()
                counters.cb = ctypes.sizeof(counters)
                ok = ctypes.windll.psapi.GetProcessMemoryInfo(
                    handle, ctypes.byref(counters), counters.cb
                )
                if not ok:
                    return None
                return int(counters.WorkingSetSize)
            finally:
                ctypes.windll.kernel32.CloseHandle(handle)
    except Exception:  # noqa: BLE001
        return None
    return None


def format_mib(n: int) -> str:
    return f"{n / (1024 * 1024):.0f} MiB"


@dataclass
class MemController:
    warned: bool = False
    last_total: Optional[int] = None
    last_avail: Optional[int] = None
    last_swap_used: Optional[int] = None
    swap_baseline: Optional[int] = None
    swap_samples: deque = field(default_factory=deque)
    swap_block_logged_at: float = 0.0

    def note_swap(self, swap_used: int, now: float) -> None:
        """Record one swap sample and relax the baseline on a long plateau."""
        self.last_swap_used = swap_used
        if self.swap_baseline is None:
            self.swap_baseline = swap_used
        self.swap_samples.append((now, swap_used))
        cutoff = now - SWAP_BASELINE_WINDOW_S
        while self.swap_samples and self.swap_samples[0][0] < cutoff:
            self.swap_samples.popleft()
        self._relax_baseline(now)

    def sample(self, now: Optional[float] = None) -> Optional[float]:
        if now is None:
            now = time.time()
        info = mem_bytes()
        if info is None:
            return None
        total, avail, swap_total, swap_free = info
        self.last_total = total
        self.last_avail = avail
        if swap_total > 0:
            self.note_swap(max(0, swap_total - swap_free), now)
        if total <= 0:
            return None
        return max(0.0, min(1.0, 1.0 - avail / total))

    def _value_before(self, age_s: float, now: float) -> Optional[int]:
        cutoff = now - age_s
        older = [v for t, v in self.swap_samples if t <= cutoff]
        return older[-1] if older else None

    def _relax_baseline(self, now: float) -> None:
        """Accept a plateau as the new normal so old spikes stop blocking growth.

        Samples are retained for SWAP_BASELINE_WINDOW_S. The plateau is only
        the last SWAP_BASELINE_STABLE_S of that window, so the check does not
        require the oldest retained sample to be older than the stable period.
        """
        if len(self.swap_samples) < 2:
            return
        stable_from = now - SWAP_BASELINE_STABLE_S
        if self.swap_samples[0][0] > stable_from:
            return
        values = [v for t, v in self.swap_samples if t >= stable_from]
        if len(values) < 2:
            return
        if max(values) - min(values) <= SWAP_ALARM_BYTES:
            self.swap_baseline = min(values)

    def swap_growth(self) -> int:
        """Bytes of swap added since the baseline (0 if none or unmeasured)."""
        if self.last_swap_used is None or self.swap_baseline is None:
            return 0
        return max(0, self.last_swap_used - self.swap_baseline)

    def swap_growing(self, now: Optional[float] = None) -> bool:
        """True while swap keeps climbing well above the baseline.

        A flat plateau, or jitter smaller than SWAP_GROW_STEP_BYTES over
        SWAP_WINDOW_S, does not count. Missing history does not count either.
        """
        if self.swap_growth() <= SWAP_ALARM_BYTES:
            return False
        if now is None:
            now = time.time()
        earlier = self._value_before(SWAP_WINDOW_S, now)
        if earlier is None:
            return False
        return (self.last_swap_used or 0) - earlier >= SWAP_GROW_STEP_BYTES


def metatile_cost_key(mt: MetaTile) -> Tuple[int, int]:
    """Cost bucket: zoom plus core edge length, since both drive memory use."""
    return mt.z, max(mt.width_tiles, mt.height_tiles)


@dataclass
class WorkerCostTracker:
    """Peak process weight per in-flight pid; median of the last N metatiles per bucket."""

    peaks: Dict[int, int] = field(default_factory=dict)
    by_key: Dict[Tuple[int, int], deque] = field(default_factory=dict)

    def begin(self, pid: int) -> None:
        self.peaks[pid] = 0
        self.sample(pid)

    def sample(self, pid: int) -> None:
        pss = process_pss_bytes(pid)
        if pss is None:
            return
        self.peaks[pid] = max(self.peaks.get(pid, 0), pss)

    def sample_all(self, pids: Sequence[int]) -> None:
        for pid in pids:
            self.sample(pid)

    def _record(self, key: Tuple[int, int], peak: int) -> None:
        if peak <= 0:
            return
        bucket = self.by_key.setdefault(key, deque(maxlen=PSS_WINDOW))
        bucket.append(peak)

    def finish(self, pid: int, key: Optional[Tuple[int, int]]) -> Optional[int]:
        peak = self.peaks.pop(pid, None)
        if peak and key is not None:
            self._record(key, peak)
        return peak

    def abort(self, pid: int, key: Optional[Tuple[int, int]]) -> None:
        self.finish(pid, key)

    def median_for(self, key: Tuple[int, int]) -> Optional[int]:
        bucket = self.by_key.get(key)
        if not bucket or len(bucket) < PSS_MIN_SAMPLES:
            return None
        return int(statistics.median(bucket))

    def has_any_median(self) -> bool:
        return any(len(b) >= PSS_MIN_SAMPLES for b in self.by_key.values())

    def max_observed(self) -> Optional[int]:
        vals = [v for v in self.peaks.values() if v]
        for bucket in self.by_key.values():
            vals.extend(bucket)
        return max(vals) if vals else None


def decide_target_jobs(
    *,
    used: Optional[float],
    available: Optional[int],
    total: Optional[int],
    median_pss: Optional[int],
    current: int,
    max_jobs: int,
) -> int:
    """Grow by 1 if another median-cost worker still fits under GROW_HEADROOM."""
    if used is None or current >= max_jobs:
        return current
    if (
        median_pss
        and available is not None
        and total
        and total > 0
    ):
        room = available - (1.0 - GROW_HEADROOM) * total
        if room > PSS_GROW_MARGIN * median_pss:
            return current + 1
    return current


def metatile_tiles_present(mt: MetaTile, out_dir: str, fmt: str) -> bool:
    """True when every core tile of this metatile is already a non-empty file."""
    for ty in range(mt.y0, mt.y1 + 1):
        for tx in range(mt.x0, mt.x1 + 1):
            path = os.path.join(out_dir, str(mt.z), str(tx), f"{ty}.{fmt}")
            if not os.path.isfile(path) or os.path.getsize(path) <= 0:
                return False
    return True


def zoom_totals(metas: Sequence[MetaTile]) -> Dict[int, Tuple[int, int]]:
    """z → (metatile count, core tile count)."""
    out: Dict[int, List[int]] = {}
    for mt in metas:
        pair = out.setdefault(mt.z, [0, 0])
        pair[0] += 1
        pair[1] += mt.tile_count
    return {z: (c[0], c[1]) for z, c in out.items()}


@dataclass
class ZoomTracker:
    expected: Dict[int, Tuple[int, int]]
    metas_done: Dict[int, int] = field(default_factory=dict)
    tiles_done: Dict[int, int] = field(default_factory=dict)
    t_first: Dict[int, float] = field(default_factory=dict)
    t_last: Dict[int, float] = field(default_factory=dict)
    jobs_integral: Dict[int, float] = field(default_factory=dict)
    last_t: Dict[int, float] = field(default_factory=dict)
    last_jobs: Dict[int, int] = field(default_factory=dict)
    logged: set = field(default_factory=set)

    def _acc_jobs(self, z: int, now: float, jobs: int) -> None:
        prev_t = self.last_t.get(z)
        prev_j = self.last_jobs.get(z, jobs)
        if prev_t is not None:
            self.jobs_integral[z] = self.jobs_integral.get(z, 0.0) + prev_j * (
                now - prev_t
            )
        self.last_t[z] = now
        self.last_jobs[z] = jobs

    def add(self, z: int, tile_count: int, now: float, jobs: int) -> Optional[int]:
        """Record a finished metatile. Return z if this zoom just completed."""
        if z not in self.t_first:
            self.t_first[z] = now
        self._acc_jobs(z, now, jobs)
        self.metas_done[z] = self.metas_done.get(z, 0) + 1
        self.tiles_done[z] = self.tiles_done.get(z, 0) + tile_count
        self.t_last[z] = now
        # Completion is tracked by tiles, not metatiles: a metatile may be
        # split into smaller blocks under memory pressure, but the core tiles
        # of a zoom are always the same set.
        _need_m, need_t = self.expected.get(z, (0, 0))
        if z not in self.logged and need_t and self.tiles_done[z] >= need_t:
            self.logged.add(z)
            return z
        return None

    def log_if_done(self, z: int) -> None:
        need_m, need_t = self.expected[z]
        duration = max(0.0, self.t_last[z] - self.t_first[z])
        tiles = self.tiles_done.get(z, need_t)
        metas = self.metas_done.get(z, need_m)
        if duration > 0:
            avg_jobs = self.jobs_integral.get(z, 0.0) / duration
            if tiles:
                # Wall-clock throughput vs. job-normalized cost (avoids
                # looking "faster" just because more workers ran).
                ms_tile = 1000.0 * duration / tiles
                ms_tile_job = ms_tile * avg_jobs
                per = f"{ms_tile:.0f} ms/tile, {ms_tile_job:.0f} ms/tile·job"
            else:
                per = "--"
        else:
            avg_jobs = float(self.last_jobs.get(z, 1))
            per = "--"
        finish_progress_line()
        log(
            "INFO",
            f"z{z} done: {metas} metatiles, {tiles} tiles, "
            f"{format_duration(duration)} ({per}), avg jobs {avg_jobs:.1f}",
        )


def collect_metatiles(
    xmin: float,
    ymin: float,
    xmax: float,
    ymax: float,
    zmin: int,
    zmax: int,
    metatile: int,
    gutter: int,
    *,
    inside: bool = False,
) -> Tuple[List[MetaTile], int]:
    """All metatiles in the zoom range plus total core tile count.

    With inside=True only tiles fully contained in the bbox are kept. Edge
    metatiles shrink to that core; their gutter is still rendered and discarded.
    """
    metas: List[MetaTile] = []
    total_tiles = 0
    for z in range(zmin, zmax + 1):
        if inside:
            covered = tile_range_for_bbox(xmin, ymin, xmax, ymax, z)
            tr = tile_range_inside_bbox(xmin, ymin, xmax, ymax, z)
            dropped = covered.count - tr.count
            if tr.count == 0:
                log(
                    "INFO",
                    f"z{z}: no tile lies fully inside the bbox "
                    f"({covered.count} overlapping tile(s) skipped).",
                )
            elif dropped > 0:
                log(
                    "INFO",
                    f"z{z}: skipping {dropped} edge tile(s) that are not fully "
                    f"inside the bbox ({tr.count} kept).",
                )
        else:
            tr = tile_range_for_bbox(xmin, ymin, xmax, ymax, z)
        zoom_metas = iter_metatiles(tr, z, metatile, gutter)
        metas.extend(zoom_metas)
        total_tiles += sum(m.tile_count for m in zoom_metas)
    return hilbert_sort_metatiles(metas), total_tiles


@dataclass
class RenderContext:
    app: QgsApplication
    layers: list
    base_settings: QgsMapSettings
    crs_3857: QgsCoordinateReferenceSystem
    background: QColor


def init_render_context(
    project_path: str,
    xmin: float,
    ymin: float,
    xmax: float,
    ymax: float,
    dpi: int,
    background: QColor,
    *,
    log_info: bool,
) -> RenderContext:
    """Load the QGIS project and build MapSettings shared by sequential and worker paths."""
    QgsApplication.setPrefixPath("/usr", True)
    app = QgsApplication([], False)
    app.initQgis()
    install_qt_message_filter()

    project = QgsProject.instance()
    if not project.read(project_path):
        app.exitQgis()
        raise RuntimeError(f"Failed to read project: {project_path}")

    layers = collect_visible_layers(project)
    clipped = localize_shapeburst_layers(layers)
    if log_info and clipped:
        log(
            "INFO",
            f"Shapeburst symbols clipped to the map extent ({clipped}).",
        )
    tuned = 0
    for layer in layers:
        try:
            if tune_postgres_layer(layer):
                tuned += 1
        except Exception as exc:  # noqa: BLE001
            if log_info:
                log("WARN", f"Could not tune datasource of {layer.name()}: {exc}")
    valid = sum(1 for layer in layers if layer.isValid())
    if log_info and tuned:
        log(
            "INFO",
            f"Postgres providers: estimatedmetadata=true, "
            f"checkPrimaryKeyUnicity=0 ({tuned} layers).",
        )
    if log_info:
        log("INFO", f"Loaded project with {valid} visible layer(s).")
    if valid == 0:
        app.exitQgis()
        raise RuntimeError(
            "No valid visible layers — check PGUSER/PGPASSFILE and DB connectivity."
        )

    # Symbols/textures use @project_folder + '/symbols/...' — MapSettings needs the
    # project expression context or data-defined SVG/raster paths stay empty (QGIS "?").
    project_dir = project.absolutePath()
    if project_dir and not project.presetHomePath():
        project.setPresetHomePath(project_dir)

    project_crs = project.crs()
    crs_3857 = QgsCoordinateReferenceSystem("EPSG:3857")
    if not project_crs.isValid():
        app.exitQgis()
        raise RuntimeError("Project CRS is invalid.")
    if project_crs.authid() != "EPSG:3857":
        app.exitQgis()
        raise RuntimeError(
            f"Project CRS is {project_crs.authid()}; expected EPSG:3857 "
            "(direct Web Mercator tile rendering + @mercator_scale)."
        )

    scale, scale_desc = resolve_mercator_scale(project, xmin, ymin, xmax, ymax)
    QgsExpressionContextUtils.setProjectVariable(project, "mercator_scale", scale)
    if log_info:
        log("INFO", f"@mercator_scale: {scale_desc}")

    base_settings = QgsMapSettings()
    base_settings.setDestinationCrs(crs_3857)
    base_settings.setOutputDpi(dpi)
    base_settings.setEllipsoid(project.ellipsoid())
    base_settings.setBackgroundColor(background)
    base_settings.setFlag(QgsMapSettings.Antialiasing, True)
    base_settings.setFlag(QgsMapSettings.DrawLabeling, True)
    # Layer opacity and blend modes (e.g. "roof shape") need this flag. Intermediate
    # effect buffers can emit QPainter engine==0 warnings headless; those are filtered.
    base_settings.setFlag(QgsMapSettings.UseAdvancedEffects, True)
    base_settings.setFlag(QgsMapSettings.LosslessImageRendering, True)
    base_settings.setFlag(QgsMapSettings.RenderMapTile, True)
    # Synchronous SVG/raster load — required for one-shot metatile jobs (no canvas refresh).
    base_settings.setFlag(QgsMapSettings.RenderBlocking, True)
    base_settings.setTransformContext(project.transformContext())
    base_settings.setPathResolver(project.pathResolver())
    base_settings.setExpressionContext(project.createExpressionContext())
    if log_info:
        log("INFO", f"Project folder for symbols: {project_dir}")
        log(
            "INFO",
            "Render CRS EPSG:3857 (direct, no warp); ground metres via @mercator_scale",
        )

    return RenderContext(app, layers, base_settings, crs_3857, background)


_worker: Dict[str, Any] = {}


def _worker_atexit() -> None:
    app = _worker.get("app")
    if app is not None:
        app.exitQgis()
        _worker["app"] = None


def _harden_worker_process() -> None:
    """Make the kernel's OOM killer prefer a render worker over the parent or Postgres."""
    if not sys.platform.startswith("linux"):
        return
    try:
        with open("/proc/self/oom_score_adj", "w", encoding="utf-8") as fh:
            fh.write(str(WORKER_OOM_SCORE_ADJ))
    except OSError:
        pass


def _init_worker(cfg: dict) -> None:
    """Spawn-process initializer: one QgsApplication per worker."""
    _harden_worker_process()
    _, background = parse_background_color(cfg["background"])
    ctx = init_render_context(
        cfg["project"],
        cfg["xmin"],
        cfg["ymin"],
        cfg["xmax"],
        cfg["ymax"],
        cfg["dpi"],
        background,
        log_info=False,
    )
    _worker["ctx"] = ctx
    _worker["app"] = ctx.app
    _worker["out"] = cfg["out"]
    _worker["fmt"] = cfg["fmt"]
    _worker["quality"] = cfg["quality"]
    atexit.register(_worker_atexit)


def _worker_render_metatile(mt: MetaTile) -> dict:
    try:
        ctx: RenderContext = _worker["ctx"]
        written = render_metatile(
            ctx.base_settings,
            ctx.layers,
            mt,
            _worker["out"],
            _worker["fmt"],
            _worker["quality"],
            ctx.crs_3857,
            ctx.background,
        )
        return {
            "type": "done",
            "ok": True,
            "pid": os.getpid(),
            "mt": mt,
            "z": mt.z,
            "tile_count": mt.tile_count,
            "written": written,
        }
    except Exception as exc:  # noqa: BLE001 — send message back to parent
        return {
            "type": "done",
            "ok": False,
            "pid": os.getpid(),
            "mt": mt,
            "error": str(exc),
            "z": mt.z,
        }


def _should_retire(retire_n) -> bool:
    with retire_n.get_lock():
        if retire_n.value > 0:
            retire_n.value -= 1
            return True
    return False


def _mt_label(mt: MetaTile) -> str:
    return f"z{mt.z} x{mt.x0}-{mt.x1} y{mt.y0}-{mt.y1}"


def _worker_main(cfg, task_queue, result_queue, retire_n, stop_event, current_jobs) -> None:
    try:
        _init_worker(cfg)
    except Exception as exc:  # noqa: BLE001
        result_queue.put(
            {
                "type": "done",
                "ok": False,
                "error": f"Worker init failed: {exc}",
                "z": None,
                "pid": os.getpid(),
            }
        )
        return
    pid = os.getpid()
    rendered = 0
    try:
        while not stop_event.is_set():
            if _should_retire(retire_n):
                break
            try:
                mt = task_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            if mt is _WORKER_SENTINEL:
                task_queue.task_done()
                break
            # current_jobs is the parent's fallback for a crash between get()
            # and the "started" message, so clear it before reporting "done".
            current_jobs[pid] = mt
            try:
                result_queue.put({"type": "started", "pid": pid, "mt": mt})
                result = _worker_render_metatile(mt)
            finally:
                current_jobs.pop(pid, None)
            result_queue.put(result)
            task_queue.task_done()
            rendered += 1
            if rendered >= WORKER_MAX_METAS:
                # Recycle: QGIS/GDAL caches and heap fragmentation only grow.
                break
            if _should_retire(retire_n):
                break
    finally:
        current_jobs.pop(pid, None)
        _worker_atexit()


def _alive_workers(workers: list) -> list:
    return [p for p in workers if p.is_alive()]


def _start_worker(
    ctx_mp, cfg, task_queue, result_queue, retire_n, stop_event, workers, current_jobs
):
    proc = ctx_mp.Process(
        target=_worker_main,
        args=(cfg, task_queue, result_queue, retire_n, stop_event, current_jobs),
        name=f"srk-tile-{len(workers)}",
    )
    proc.start()
    workers.append(proc)


def _pick_emergency_victim(workers, in_flight, current_jobs):
    """Youngest in-flight worker, or the most recently started idle process."""
    alive = _alive_workers(workers)
    if not alive:
        return None, None
    candidates = []
    for proc in alive:
        pid = proc.pid
        if pid in in_flight:
            started, mt, _ = in_flight[pid]
            candidates.append((started, proc, mt))
        elif pid in current_jobs:
            candidates.append((time.time(), proc, current_jobs[pid]))
    if candidates:
        _started, proc, mt = max(candidates, key=lambda item: item[0])
        return proc, mt
    return alive[-1], None


def _emergency_kill_worker(proc, workers, in_flight, killed_pids, current_jobs) -> None:
    """Kill a worker; the caller re-queues its metatile."""
    pid = proc.pid
    if pid is not None:
        killed_pids.add(pid)
        in_flight.pop(pid, None)
        try:
            current_jobs.pop(pid, None)
        except Exception:  # noqa: BLE001
            pass
    if proc.is_alive():
        proc.kill()
        proc.join(timeout=5)
        if proc.is_alive():
            proc.terminate()
            proc.join(timeout=2)
    if proc in workers:
        workers.remove(proc)


def _stop_pool(workers, stop_event, task_queue) -> None:
    stop_event.set()
    for _ in list(workers):
        try:
            task_queue.put_nowait(_WORKER_SENTINEL)
        except Exception:  # noqa: BLE001
            break
    for proc in workers:
        proc.join(timeout=20)
        if proc.is_alive():
            proc.terminate()
            proc.join(timeout=5)


def render_sequential(
    ctx: RenderContext,
    metas: Sequence[MetaTile],
    out_dir: str,
    fmt: str,
    quality: int,
    zmax: int,
    total_tiles: int,
    expected: Dict[int, Tuple[int, int]],
) -> int:
    start = time.time()
    done_tiles = 0
    done_metas = 0
    written_total = 0
    total_metas = len(metas)
    tracker = ZoomTracker(expected=expected)
    try:
        for mt in metas:
            written = render_metatile(
                ctx.base_settings,
                ctx.layers,
                mt,
                out_dir,
                fmt,
                quality,
                ctx.crs_3857,
                ctx.background,
            )
            written_total += written
            done_tiles += mt.tile_count
            done_metas += 1
            now = time.time()
            finished_z = tracker.add(mt.z, mt.tile_count, now, 1)
            print_progress(
                zoom=mt.z,
                zmax=zmax,
                meta_done=done_metas,
                meta_total=total_metas,
                done_tiles=done_tiles,
                total_tiles=total_tiles,
                elapsed=now - start,
                jobs=1,
            )
            if finished_z is not None:
                tracker.log_if_done(finished_z)
        return written_total
    finally:
        finish_progress_line()


def render_parallel(
    cfg: dict,
    metas: Sequence[MetaTile],
    *,
    initial_jobs: int,
    max_jobs: int,
    dynamic: bool,
    zmax: int,
    total_tiles: int,
    expected: Dict[int, Tuple[int, int]],
    metatile: int,
    gutter: int,
) -> int:
    start = time.time()
    done_tiles = 0
    done_metas = 0
    written_total = 0
    tracker = ZoomTracker(expected=expected)
    mem = MemController()
    cost = WorkerCostTracker()
    last_ctrl = 0.0
    last_key: Optional[Tuple[int, int]] = None
    last_bootstrap = start
    emergency_until = 0.0
    emergency_ever = False
    # Work waits on the parent side; the task queue stays shallow so a reduced
    # metatile cap takes effect on the very next dispatch.
    pending: deque = deque(metas)
    queued = 0
    in_flight: Dict[int, Tuple[float, MetaTile, Any]] = {}
    done_ids: set = set()
    killed_pids: set = set()
    dead_seen: Dict[int, float] = {}
    job_ceiling = max_jobs
    size_cap = max(MIN_METATILE, metatile)
    stable_metas = 0
    last_pressure = 0.0
    idle_since: Optional[float] = None
    logged_last_worker = False
    ctx_mp = multiprocessing.get_context("spawn")
    manager = ctx_mp.Manager()
    current_jobs = manager.dict()
    task_queue = ctx_mp.JoinableQueue()
    result_queue = ctx_mp.Queue()
    retire_n = ctx_mp.Value("i", 0)
    stop_event = ctx_mp.Event()
    workers: list = []
    target = max(1, min(initial_jobs, max_jobs, len(metas)))

    def spawn_one() -> None:
        _start_worker(
            ctx_mp,
            cfg,
            task_queue,
            result_queue,
            retire_n,
            stop_event,
            workers,
            current_jobs,
        )

    def note_stable_metatile() -> None:
        """Undo memory penalties after a stretch without pressure."""
        nonlocal job_ceiling, stable_metas, size_cap
        if not dynamic:
            return
        stable_metas += 1
        if stable_metas < CEILING_RECOVERY_METAS:
            return
        if time.time() - last_pressure < RECOVERY_QUIET_S:
            # Keep the penalty: pressure was seen only moments ago.
            return
        stable_metas = 0
        if size_cap < metatile:
            size_cap = min(metatile, size_cap * 2)
            log(
                "INFO",
                f"RAM stable for {CEILING_RECOVERY_METAS} metatiles; "
                f"raising metatile cap to {size_cap}x{size_cap}",
            )
        elif job_ceiling < max_jobs:
            job_ceiling += 1
            log(
                "INFO",
                f"RAM stable for {CEILING_RECOVERY_METAS} metatiles; "
                f"raising job cap to {job_ceiling}",
            )

    def meta_total_estimate() -> int:
        return done_metas + len(pending) + queued + len(in_flight)

    def work_left() -> bool:
        if done_tiles >= total_tiles:
            return False
        return bool(pending) or queued > 0 or bool(in_flight)

    def apply_result(result: dict) -> None:
        nonlocal done_tiles, done_metas, written_total, last_ctrl, last_key
        nonlocal queued
        kind = result.get("type", "done")
        pid = result.get("pid")
        if kind == "started":
            mt = result.get("mt")
            queued = max(0, queued - 1)
            if pid is None or mt is None or pid in killed_pids:
                return
            proc = next((p for p in workers if p.pid == pid), None)
            if proc is not None:
                in_flight[pid] = (time.time(), mt, proc)
                cost.begin(pid)
            return

        if pid is not None:
            in_flight.pop(pid, None)
            if pid in killed_pids:
                cost.peaks.pop(pid, None)
                return

        if not result.get("ok"):
            raise RuntimeError(result.get("error") or "Worker failed")

        mt = result.get("mt")
        key = metatile_cost_key(mt) if mt is not None else None
        if pid is not None:
            cost.finish(pid, key)
        if key is not None:
            last_key = key
        if mt is not None:
            mt_id = (mt.z, mt.x0, mt.x1, mt.y0, mt.y1)
            if mt_id in done_ids:
                # A re-queued metatile whose original result arrived late.
                return
            done_ids.add(mt_id)
        z = int(result["z"])
        tile_count = int(result["tile_count"])
        written_total += int(result["written"])
        done_tiles += tile_count
        done_metas += 1
        now = time.time()
        jobs_n = len(_alive_workers(workers))
        finished_z = tracker.add(z, tile_count, now, max(1, jobs_n))
        print_progress(
            zoom=z,
            zmax=zmax,
            meta_done=done_metas,
            meta_total=max(done_metas, meta_total_estimate()),
            done_tiles=done_tiles,
            total_tiles=total_tiles,
            elapsed=now - start,
            jobs=max(1, jobs_n),
        )
        if finished_z is not None:
            tracker.log_if_done(finished_z)
        note_stable_metatile()
        if dynamic:
            last_ctrl = min(last_ctrl, now - MEM_SAMPLE_S)

    def drain_results(*, block_s: Optional[float] = None) -> bool:
        got = False
        if block_s is not None:
            try:
                apply_result(result_queue.get(timeout=block_s))
                got = True
            except queue.Empty:
                return False
        while True:
            try:
                apply_result(result_queue.get_nowait())
                got = True
            except queue.Empty:
                break
        return got

    def feed_queue() -> None:
        """Keep the task queue just deep enough that no worker idles."""
        nonlocal queued
        depth = len(_alive_workers(workers)) + 1
        while pending and queued < depth:
            for part in split_metatile(pending.popleft(), size_cap, gutter):
                task_queue.put(part)
                queued += 1

    def shrink_tile_cap(reason: str) -> bool:
        """Halve the metatile core so a single worker needs less peak memory."""
        nonlocal size_cap, stable_metas
        if size_cap <= MIN_METATILE:
            return False
        old = size_cap
        size_cap = max(MIN_METATILE, size_cap // 2)
        stable_metas = 0
        log(
            "WARN",
            f"{reason}; reducing metatile size {old}x{old} → "
            f"{size_cap}x{size_cap}",
        )
        return True

    def reap_dead_workers(now: float) -> None:
        """Account for exited workers and rescue metatiles lost to a crash."""
        nonlocal target, job_ceiling, stable_metas, emergency_until, last_pressure
        nonlocal queued
        oom = False
        for proc in list(workers):
            if proc.is_alive():
                continue
            pid = proc.pid
            first_seen = dead_seen.setdefault(pid, now)
            if now - first_seen < DEAD_GRACE_S:
                # Let results still travelling through the queue land first.
                continue
            workers.remove(proc)
            dead_seen.pop(pid, None)
            cost.peaks.pop(pid, None)
            if pid in killed_pids:
                continue
            entry = in_flight.pop(pid, None)
            lost = entry[1] if entry is not None else None
            if lost is None:
                # Crash between task_queue.get() and the "started" message.
                try:
                    lost = current_jobs.get(pid)
                except Exception:  # noqa: BLE001
                    lost = None
                if lost is not None:
                    # No "started" arrived, so its queue slot is still counted.
                    queued = max(0, queued - 1)
            try:
                current_jobs.pop(pid, None)
            except Exception:  # noqa: BLE001
                pass
            if lost is None:
                continue  # clean exit: retired or recycled
            pending.appendleft(lost)
            code = proc.exitcode
            if code == -9:
                oom = True
            hint = " (OOM killer)" if code == -9 else ""
            log(
                "WARN",
                f"Worker pid={pid} died unexpectedly, exitcode {code}{hint}, "
                f"while rendering {_mt_label(lost)}; metatile re-queued",
            )
        if oom and dynamic:
            last_pressure = now
            alive_n = max(1, len(_alive_workers(workers)))
            if alive_n > 1 or size_cap <= MIN_METATILE:
                job_ceiling = min(job_ceiling, alive_n)
                target = min(target, alive_n)
                log("INFO", f"Job cap lowered to {job_ceiling} after an OOM kill")
            else:
                shrink_tile_cap("OOM killer hit the last worker")
            stable_metas = 0
            emergency_until = now + EMERGENCY_COOLDOWN_S

    def reconcile_target(now: float) -> None:
        """Replace recycled or crashed workers so the pool matches target."""
        nonlocal target
        cap = max(1, min(max_jobs, job_ceiling))
        if target > cap:
            target = cap
        if now < emergency_until or not work_left():
            return
        missing = target - len(_alive_workers(workers))
        if missing <= 0:
            return
        with retire_n.get_lock():
            pending_retire = retire_n.value
        if pending_retire > 0:
            return
        for _ in range(missing):
            spawn_one()

    def wait_and_respawn(used: Optional[float]) -> None:
        nonlocal target, job_ceiling, stable_metas, last_pressure
        job_ceiling = 1
        stable_metas = 0
        if used is not None:
            state = f"RAM {used:.0%}"
        else:
            state = "RAM unknown"
        if mem.swap_growth() > SWAP_ALARM_BYTES:
            state += f", swap +{format_mib(mem.swap_growth())}"
        log(
            "WARN",
            f"No tile workers left ({state}); waiting for memory to free up "
            f"before restarting one.",
        )
        wait_start = time.time()
        next_shrink = wait_start + NO_WORKER_SHRINK_S
        while work_left():
            time.sleep(1.0)
            drain_results()
            now = time.time()
            sampled = mem.sample(now)
            blocked = (sampled is not None and sampled >= GROW_HEADROOM) or (
                mem.swap_growing(now)
            )
            waited = now - wait_start
            if blocked:
                last_pressure = now
            if blocked and waited < NO_WORKER_FORCE_S:
                if now >= next_shrink:
                    next_shrink = now + NO_WORKER_SHRINK_S
                    shrink_tile_cap(
                        f"No worker could start for {waited:.0f}s under memory pressure"
                    )
                continue
            spawn_one()
            target = 1
            ram_s = "unknown" if sampled is None else f"{sampled:.0%}"
            if blocked:
                # Something outside this render holds the memory; waiting
                # longer would stall the run indefinitely.
                log(
                    "WARN",
                    f"Starting 1 QGIS worker despite RAM {ram_s} after waiting "
                    f"{waited:.0f}s (metatile {size_cap}x{size_cap}).",
                )
            else:
                log(
                    "INFO",
                    f"Restarted 1 QGIS worker after RAM {ram_s} < {GROW_HEADROOM:.0%}.",
                )
            return

    def maybe_emergency(used: Optional[float], now: float) -> Optional[float]:
        nonlocal target, emergency_until, job_ceiling, stable_metas
        nonlocal logged_last_worker, emergency_ever, last_pressure, queued
        ram_full = used is not None and used >= EMERGENCY_USED
        swap_up = mem.swap_growing(now)
        if not (ram_full or swap_up):
            logged_last_worker = False
            return used
        last_pressure = now
        if now < emergency_until:
            return used
        if ram_full:
            reason = f"RAM {used:.0%} ≥ {EMERGENCY_USED:.0%}"
        else:
            reason = f"swap grew {format_mib(mem.swap_growth())} above baseline"
        alive_n = len(_alive_workers(workers))
        if alive_n <= 1:
            # Dropping the last job would stall the render, so shrink its work.
            if shrink_tile_cap(reason):
                emergency_until = now + EMERGENCY_COOLDOWN_S
                logged_last_worker = False
            elif not logged_last_worker:
                log(
                    "WARN",
                    f"{reason}, but only one worker at the smallest metatile "
                    f"({size_cap}x{size_cap}) remains; letting it finish",
                )
                logged_last_worker = True
            return mem.sample(time.time())
        logged_last_worker = False
        proc, mt = _pick_emergency_victim(workers, in_flight, current_jobs)
        if proc is None:
            return used
        emergency_ever = True
        pid = proc.pid
        label = _mt_label(mt) if mt is not None else "idle"
        log(
            "WARN",
            f"{reason}; killing youngest worker pid={pid} ({label}); "
            f"jobs {alive_n} → {max(0, alive_n - 1)}",
        )
        key = metatile_cost_key(mt) if mt is not None else None
        was_started = pid in in_flight
        _emergency_kill_worker(proc, workers, in_flight, killed_pids, current_jobs)
        cost.abort(pid, key)
        if mt is not None:
            pending.appendleft(mt)
            if not was_started:
                queued = max(0, queued - 1)
        else:
            log(
                "WARN",
                f"Killed worker pid={pid} had no tracked metatile; "
                "work may need a re-run if a tile is missing.",
            )
        with retire_n.get_lock():
            retire_n.value = 0
        alive_n = len(_alive_workers(workers))
        target = max(1, alive_n)
        job_ceiling = max(1, alive_n)
        stable_metas = 0
        emergency_until = time.time() + EMERGENCY_COOLDOWN_S
        log(
            "INFO",
            f"Job cap lowered to {job_ceiling} until "
            f"{CEILING_RECOVERY_METAS} metatiles complete without a RAM kill",
        )
        return mem.sample(time.time())

    def worst_median() -> Tuple[Optional[Tuple[int, int]], Optional[int]]:
        """Most expensive known bucket among the metatiles currently in flight."""
        keys = {metatile_cost_key(mt) for _t, mt, _p in in_flight.values()}
        if last_key is not None:
            keys.add(last_key)
        worst_key: Optional[Tuple[int, int]] = None
        worst: Optional[int] = None
        for key in keys:
            med = cost.median_for(key)
            if med and (worst is None or med > worst):
                worst_key, worst = key, med
        return worst_key, worst

    def scale_jobs(used: Optional[float]) -> None:
        nonlocal target, last_bootstrap
        remaining = len(pending) + queued + len(in_flight)
        cap = min(max_jobs, job_ceiling, max(1, remaining))
        if used is None and not mem.warned:
            mem.warned = True
            log(
                "WARN",
                "Could not read available RAM; keeping current worker count",
            )
        now = time.time()
        if now < emergency_until:
            return
        if mem.swap_growing(now):
            if target < cap and now - mem.swap_block_logged_at >= SWAP_WINDOW_S:
                mem.swap_block_logged_at = now
                log(
                    "INFO",
                    f"Holding worker count at {target}: swap is "
                    f"{format_mib(mem.swap_growth())} above baseline and still "
                    f"growing.",
                )
            return
        key, median_pss = worst_median()
        extra_note = ""
        if median_pss:
            new_target = decide_target_jobs(
                used=used,
                available=mem.last_avail,
                total=mem.last_total,
                median_pss=median_pss,
                current=target,
                max_jobs=cap,
            )
        elif (
            not emergency_ever
            and not cost.has_any_median()
            and now - last_bootstrap >= BOOTSTRAP_S
        ):
            last_bootstrap = now
            peak = cost.max_observed()
            new_target = target
            total = mem.last_total
            if (
                peak
                and total
                and target < cap
                and (target + 1) * peak <= total * GROW_HEADROOM
            ):
                new_target = target + 1
                extra_note = (
                    f"bootstrap {BOOTSTRAP_S:.0f}s, peak {format_mib(peak)}/job"
                )
        else:
            new_target = target
        if new_target > target:
            with retire_n.get_lock():
                pending_retire = retire_n.value
            if pending_retire > 0:
                return
            extra = new_target - target
            for _ in range(extra):
                spawn_one()
            target = new_target
            if key is not None:
                key_s = f"z{key[0]} {key[1]}x{key[1]} "
            else:
                key_s = ""
            med_s = format_mib(median_pss) if median_pss else "?"
            ram_s = f", RAM {used:.0%}" if used is not None else ""
            note = extra_note or f"{key_s}median peak {med_s}/job"
            log(
                "INFO",
                f"Starting {extra} extra worker(s) ({note}{ram_s}, cap {cap}).",
            )

    try:
        for _ in range(target):
            spawn_one()
        log(
            "INFO",
            f"Started {target} QGIS worker process(es) "
            f"({'dynamic' if dynamic else 'fixed'}, cap {max_jobs}, "
            f"metatile {size_cap}x{size_cap}).",
        )
        feed_queue()

        while work_left():
            drain_results()
            if not work_left():
                break

            now = time.time()
            used = mem.sample(now) if dynamic else None
            reap_dead_workers(now)
            if dynamic:
                cost.sample_all(list(in_flight.keys()))
                used = maybe_emergency(used, now)

            if not _alive_workers(workers):
                pressure = (
                    used is not None and used >= GROW_HEADROOM
                ) or mem.swap_growing(now)
                if dynamic and pressure:
                    wait_and_respawn(used)
                else:
                    # Workers exit on purpose for recycling; just replace them.
                    spawn_one()
                feed_queue()
                continue

            if dynamic and now - last_ctrl >= MEM_SAMPLE_S:
                last_ctrl = now
                scale_jobs(used)
            reconcile_target(now)
            feed_queue()
            if drain_results(block_s=1.0):
                idle_since = None
            elif pending or in_flight or not task_queue.empty():
                idle_since = None
            elif idle_since is None:
                idle_since = time.time()
            elif time.time() - idle_since >= STUCK_TIMEOUT_S:
                # Nothing queued, nothing running, nothing arriving: the
                # bookkeeping lost a task. Stop instead of spinning forever.
                log(
                    "WARN",
                    f"No progress for {STUCK_TIMEOUT_S:.0f}s with an empty queue; "
                    "giving up on the remaining metatiles",
                )
                queued = 0
                break

        drain_results()
        if done_tiles < total_tiles:
            log(
                "WARN",
                f"Only {done_tiles}/{total_tiles} tiles were rendered; "
                "re-run the command to fill the gaps.",
            )
        return written_total
    except KeyboardInterrupt:
        raise RuntimeError("Interrupted") from None
    finally:
        finish_progress_line()
        _stop_pool(workers, stop_event, task_queue)
        manager.shutdown()


def run(args: argparse.Namespace) -> int:
    xmin, ymin, xmax, ymax = parse_extent(args.extent)
    fmt = normalize_tile_format(args.format)
    try:
        bg_hex, background = parse_background_color(args.background)
    except ValueError as exc:
        log("ERROR", str(exc))
        return 1

    metas, total_tiles = collect_metatiles(
        xmin,
        ymin,
        xmax,
        ymax,
        args.zmin,
        args.zmax,
        args.metatile,
        args.gutter,
        inside=args.inside,
    )
    if args.resume:
        kept: List[MetaTile] = []
        skipped_metas = 0
        skipped_tiles = 0
        for mt in metas:
            if metatile_tiles_present(mt, args.out, fmt):
                skipped_metas += 1
                skipped_tiles += mt.tile_count
            else:
                kept.append(mt)
        if skipped_metas:
            log(
                "INFO",
                f"Resume: skipping {skipped_metas} metatiles "
                f"({skipped_tiles} tiles) already on disk.",
            )
        metas = kept
        total_tiles = sum(mt.tile_count for mt in metas)
    total_metas = len(metas)
    expected = zoom_totals(metas)
    jobs_arg = args.jobs

    if jobs_arg == "dynamic":
        jobs_label = "dynamic"
    else:
        jobs_label = str(min(int(jobs_arg), max(1, total_metas)))

    log(
        "INFO",
        f"Rendering XYZ tiles z{args.zmin}-{args.zmax} "
        f"(~{total_tiles} tiles, {total_metas} metatiles, "
        f"metatile={args.metatile}, gutter={args.gutter}, "
        f"jobs={jobs_label}, bg={bg_hex}"
        f"{', inside' if args.inside else ''}) → {args.out}",
    )
    os.makedirs(args.out, exist_ok=True)

    if total_metas == 0:
        log("INFO", "Rendering completed in 0s (0 tiles written).")
        return 0

    worker_cfg = {
        "project": args.project,
        "xmin": xmin,
        "ymin": ymin,
        "xmax": xmax,
        "ymax": ymax,
        "dpi": args.dpi,
        "background": bg_hex,
        "out": args.out,
        "fmt": fmt,
        "quality": args.quality,
    }

    start = time.time()
    try:
        if jobs_arg == "dynamic":
            if mem_used_fraction() is None:
                log(
                    "WARN",
                    "Could not read available RAM; --jobs dynamic "
                    f"falling back to {DYNAMIC_JOBS_FALLBACK}",
                )
                n = min(DYNAMIC_JOBS_FALLBACK, total_metas)
                if n <= 1:
                    jobs_arg = 1
                else:
                    written_total = render_parallel(
                        worker_cfg,
                        metas,
                        initial_jobs=n,
                        max_jobs=n,
                        dynamic=False,
                        zmax=args.zmax,
                        total_tiles=total_tiles,
                        expected=expected,
                        metatile=args.metatile,
                        gutter=args.gutter,
                    )
                    elapsed = time.time() - start
                    log(
                        "INFO",
                        f"Rendering completed in {format_duration(elapsed)} "
                        f"({written_total} tiles written).",
                    )
                    return 0
            else:
                # Leave one logical core for OS / Postgres / UI.
                cap = max(1, min((os.cpu_count() or 1) - 1, 8, total_metas))
                if cap <= 1:
                    jobs_arg = 1
                else:
                    written_total = render_parallel(
                        worker_cfg,
                        metas,
                        initial_jobs=1,
                        max_jobs=cap,
                        dynamic=True,
                        zmax=args.zmax,
                        total_tiles=total_tiles,
                        expected=expected,
                        metatile=args.metatile,
                        gutter=args.gutter,
                    )
                    elapsed = time.time() - start
                    log(
                        "INFO",
                        f"Rendering completed in {format_duration(elapsed)} "
                        f"({written_total} tiles written).",
                    )
                    return 0

        n_fixed = 1 if jobs_arg == 1 else min(int(jobs_arg), total_metas)
        if n_fixed <= 1:
            ctx = init_render_context(
                args.project,
                xmin,
                ymin,
                xmax,
                ymax,
                args.dpi,
                background,
                log_info=True,
            )
            try:
                written_total = render_sequential(
                    ctx,
                    metas,
                    args.out,
                    fmt,
                    args.quality,
                    args.zmax,
                    total_tiles,
                    expected,
                )
            finally:
                ctx.app.exitQgis()
        else:
            written_total = render_parallel(
                worker_cfg,
                metas,
                initial_jobs=n_fixed,
                max_jobs=n_fixed,
                dynamic=False,
                zmax=args.zmax,
                total_tiles=total_tiles,
                expected=expected,
                metatile=args.metatile,
                gutter=args.gutter,
            )
    except Exception as exc:  # noqa: BLE001
        log("ERROR", str(exc))
        return 1

    elapsed = time.time() - start
    log(
        "INFO",
        f"Rendering completed in {format_duration(elapsed)} "
        f"({written_total} tiles written).",
    )
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Render XYZ tiles via PyQGIS metatile loop")
    p.add_argument("--project", required=True, help="Path to .qgz / .qgs")
    p.add_argument(
        "--extent",
        required=True,
        help='Extent as "xmin,ymin,xmax,ymax [EPSG:4326]"',
    )
    p.add_argument("--out", required=True, help="Output tile directory")
    p.add_argument("--zmin", type=int, default=15)
    p.add_argument("--zmax", type=int, default=20)
    p.add_argument("--metatile", type=int, default=8)
    p.add_argument(
        "--gutter",
        type=int,
        default=1,
        help="Extra tiles around each metatile for labels/symbols (discarded after render)",
    )
    p.add_argument("--dpi", type=int, default=96)
    p.add_argument(
        "--background",
        default=DEFAULT_BACKGROUND,
        help=f"Tile background colour as #rrggbb (default: {DEFAULT_BACKGROUND})",
    )
    p.add_argument(
        "--format",
        default="webp",
        choices=["webp", "png", "jpg", "jpeg", "WEBP", "PNG", "JPG", "JPEG"],
    )
    p.add_argument(
        "--quality",
        type=int,
        default=95,
        help="JPEG/WebP quality 0-100 (default: 95; 100 = lossless WebP)",
    )
    p.add_argument(
        "--resume",
        action="store_true",
        help="Skip metatiles whose core tiles already exist in --out",
    )
    p.add_argument(
        "--inside",
        action="store_true",
        help="Write only tiles whose full extent lies inside the bbox",
    )
    p.add_argument(
        "--jobs",
        type=parse_jobs_arg,
        default="dynamic",
        metavar="N",
        help=(
            "Worker processes: 'dynamic' (default; start 1, bootstrap every "
            "60s if (n+1) peak worker RAM fits under 90%, then grow by "
            "median peak; cap min(CPU-1, 8); kill extra workers at 95% RAM, "
            "never the last one) "
            "or an integer >= 1 (1 = sequential)"
        ),
    )
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if args.zmin > args.zmax:
        log("ERROR", f"Invalid zoom range: {args.zmin}-{args.zmax}")
        return 1
    if args.metatile < 1:
        log("ERROR", f"Invalid metatile size: {args.metatile}")
        return 1
    if args.gutter < 0:
        log("ERROR", f"Invalid gutter: {args.gutter}")
        return 1
    if args.quality < 0 or args.quality > 100:
        log("ERROR", f"Invalid --quality: {args.quality} (use 0-100)")
        return 1
    if not os.path.isfile(args.project):
        log("ERROR", f"Project not found: {args.project}")
        return 1
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
