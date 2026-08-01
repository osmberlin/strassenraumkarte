#!/usr/bin/env python3
"""
Render XYZ map tiles from a QGIS project using a custom metatile loop.

Renders directly in EPSG:3857 (Web Mercator tile grid). Ground-metre symbol
sizes in the project are scaled via the project variable @mercator_scale
(= 1/cos(φ) under EPSG:3857).

Progress is reported after every metatile (zoom, metatile index, tiles, ETA).
Background colour defaults to #ededed (opaque); override with --background.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Sequence, Tuple, TextIO

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from qgis.core import (  # noqa: E402
    QgsApplication,
    QgsCoordinateReferenceSystem,
    QgsExpressionContext,
    QgsExpressionContextUtils,
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


def _qimage_format(name: str):
    """Qt5: QImage.Format_*; Qt6/PyQGIS 4: QImage.Format.Format_*."""
    fmt_ns = getattr(QImage, "Format", None)
    if fmt_ns is not None and hasattr(fmt_ns, name):
        return getattr(fmt_ns, name)
    return getattr(QImage, name)


def _qpainter_hint(name: str):
    """Qt5: QPainter.Antialiasing; Qt6: QPainter.RenderHint.Antialiasing."""
    hint_ns = getattr(QPainter, "RenderHint", None)
    if hint_ns is not None and hasattr(hint_ns, name):
        return getattr(hint_ns, name)
    return getattr(QPainter, name)

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
    """Parse 'xmin,xmax,ymin,ymax [EPSG:4326]' → (xmin, ymin, xmax, ymax)."""
    m = re.match(
        r"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*"
        r"(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)",
        extent,
    )
    if not m:
        raise ValueError(f"Invalid extent: {extent}")
    xmin, xmax, ymin, ymax = map(float, m.groups())
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
    line = (
        f"{pct:5.1f}%  zoom {zoom}/{zmax}  "
        f"metatiles {meta_done}/{meta_total}  "
        f"tiles {done_tiles}/{total_tiles}  "
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


def save_tile_image(
    tile: QImage,
    path: str,
    fmt: str,
    quality: int,
    background: QColor,
) -> None:
    """
    Write one tile to disk.

    JPEG has no alpha: composite the premultiplied ARGB buffer onto the opaque
    background before encoding. Saving ARGB32_Premultiplied directly as JPEG
    drops alpha incorrectly and can yield flat gray tiles.
    """
    if fmt == "jpg":
        opaque = QImage(tile.size(), _qimage_format("Format_RGB888"))
        opaque.fill(background.rgb())
        painter = QPainter(opaque)
        painter.drawImage(0, 0, tile)
        painter.end()
        opaque.save(path, "JPEG", quality)
    else:
        tile.save(path, "PNG")


def render_metatile(
    settings_template: QgsMapSettings,
    layers: Sequence,
    mt: MetaTile,
    out_dir: str,
    fmt: str,
    quality: int,
    crs_3857: QgsCoordinateReferenceSystem,
    background: QColor,
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

    image = QImage(QSize(width_px, height_px), _qimage_format("Format_ARGB32_Premultiplied"))
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
    painter.setRenderHint(_qpainter_hint("Antialiasing"), True)
    job = QgsMapRendererCustomPainterJob(settings, painter)
    job.start()
    job.waitForFinished()
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


def run(args: argparse.Namespace) -> int:
    xmin, ymin, xmax, ymax = parse_extent(args.extent)
    fmt = "jpg" if args.format.lower() in ("jpg", "jpeg") else "png"
    try:
        bg_hex, background = parse_background_color(args.background)
    except ValueError as exc:
        log("ERROR", str(exc))
        return 1

    prefix = os.environ.get("QGIS_PREFIX_PATH", "/usr")
    QgsApplication.setPrefixPath(prefix, True)
    plugin_path = os.environ.get("QGIS_PLUGIN_PATH")
    if plugin_path:
        QgsApplication.setPluginPath(plugin_path)
    pkg_data = os.environ.get("QGIS_PKG_DATA_PATH")
    if pkg_data:
        QgsApplication.setPkgDataPath(pkg_data)
    app = QgsApplication([], False)
    app.initQgis()
    install_qt_message_filter()

    project = QgsProject.instance()
    if not project.read(args.project):
        log("ERROR", f"Failed to read project: {args.project}")
        app.exitQgis()
        return 1

    layers = collect_visible_layers(project)
    valid = sum(1 for layer in layers if layer.isValid())
    log("INFO", f"Loaded project with {valid} visible layer(s).")
    if valid == 0:
        log("ERROR", "No valid visible layers — check PGUSER/PGPASSFILE and DB connectivity.")
        app.exitQgis()
        return 1

    # Symbols/textures use @project_folder + '/symbols/...' — MapSettings needs the
    # project expression context or data-defined SVG/raster paths stay empty (QGIS "?").
    project_dir = project.absolutePath()
    if project_dir and not project.presetHomePath():
        project.setPresetHomePath(project_dir)

    project_crs = project.crs()
    crs_3857 = QgsCoordinateReferenceSystem("EPSG:3857")
    if not project_crs.isValid():
        log("ERROR", "Project CRS is invalid.")
        app.exitQgis()
        return 1
    if project_crs.authid() != "EPSG:3857":
        log(
            "ERROR",
            f"Project CRS is {project_crs.authid()}; expected EPSG:3857 "
            "(direct Web Mercator tile rendering + @mercator_scale).",
        )
        app.exitQgis()
        return 1

    scale, scale_desc = resolve_mercator_scale(project, xmin, ymin, xmax, ymax)
    QgsExpressionContextUtils.setProjectVariable(project, "mercator_scale", scale)
    log("INFO", f"@mercator_scale: {scale_desc}")

    base_settings = QgsMapSettings()
    base_settings.setDestinationCrs(crs_3857)
    base_settings.setOutputDpi(args.dpi)
    base_settings.setEllipsoid(project.ellipsoid())
    base_settings.setBackgroundColor(background)
    base_settings.setFlag(QgsMapSettings.Antialiasing, True)
    base_settings.setFlag(QgsMapSettings.DrawLabeling, True)
    # Avoid QGraphicsEffect buffers (often fail headless → QPainter engine==0 warnings)
    # and keep alpha compositing predictable before JPEG export.
    base_settings.setFlag(QgsMapSettings.UseAdvancedEffects, False)
    base_settings.setFlag(QgsMapSettings.LosslessImageRendering, True)
    base_settings.setFlag(QgsMapSettings.RenderMapTile, True)
    # Synchronous SVG/raster load — required for one-shot metatile jobs (no canvas refresh).
    base_settings.setFlag(QgsMapSettings.RenderBlocking, True)
    base_settings.setTransformContext(project.transformContext())
    base_settings.setPathResolver(project.pathResolver())
    base_settings.setExpressionContext(project.createExpressionContext())
    log("INFO", f"Project folder for symbols: {project_dir}")
    log("INFO", "Render CRS EPSG:3857 (direct, no warp); ground metres via @mercator_scale")

    # Precompute metatiles / totals
    zoom_meta: List[Tuple[int, List[MetaTile]]] = []
    total_tiles = 0
    total_metas = 0
    for z in range(args.zmin, args.zmax + 1):
        tr = tile_range_for_bbox(xmin, ymin, xmax, ymax, z)
        metas = iter_metatiles(tr, z, args.metatile, args.gutter)
        zoom_meta.append((z, metas))
        total_tiles += sum(m.tile_count for m in metas)
        total_metas += len(metas)

    log(
        "INFO",
        f"Rendering XYZ tiles z{args.zmin}-{args.zmax} "
        f"(~{total_tiles} tiles, {total_metas} metatiles, "
        f"metatile={args.metatile}, gutter={args.gutter}, bg={bg_hex}) → {args.out}",
    )
    os.makedirs(args.out, exist_ok=True)

    start = time.time()
    done_tiles = 0
    done_metas = 0
    written_total = 0
    meta_timings: List[dict] = []

    audit_dir = os.environ.get("PERF_AUDIT_DIR", "").strip()
    metatile_log: Optional[TextIO] = None
    if audit_dir:
        Path(audit_dir).mkdir(parents=True, exist_ok=True)
        metatile_log = open(  # noqa: SIM115
            Path(audit_dir) / "render_metatiles.jsonl",
            "a",
            encoding="utf-8",
        )

    render_error: Optional[str] = None
    try:
        for z, metas in zoom_meta:
            for mt in metas:
                t0 = time.time()
                written = render_metatile(
                    base_settings,
                    layers,
                    mt,
                    args.out,
                    fmt,
                    args.quality,
                    crs_3857,
                    background,
                )
                dt_ms = int((time.time() - t0) * 1000)
                written_total += written
                done_tiles += mt.tile_count
                done_metas += 1
                row = {
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "z": z,
                    "x0": mt.x0,
                    "y0": mt.y0,
                    "x1": mt.x1,
                    "y1": mt.y1,
                    "tiles": mt.tile_count,
                    "written": written,
                    "duration_ms": dt_ms,
                }
                meta_timings.append(row)
                if metatile_log is not None:
                    metatile_log.write(json.dumps(row, ensure_ascii=False) + "\n")
                    metatile_log.flush()
                print_progress(
                    zoom=z,
                    zmax=args.zmax,
                    meta_done=done_metas,
                    meta_total=total_metas,
                    done_tiles=done_tiles,
                    total_tiles=total_tiles,
                    elapsed=time.time() - start,
                )
    except RuntimeError as exc:
        render_error = str(exc)
    finally:
        finish_progress_line()
        if metatile_log is not None:
            metatile_log.close()
        app.exitQgis()

    if render_error:
        log("ERROR", render_error)
        return 1

    elapsed = time.time() - start
    log(
        "INFO",
        f"Rendering completed in {format_duration(elapsed)} "
        f"({written_total} tiles written).",
    )

    if audit_dir and meta_timings:
        durations = [r["duration_ms"] for r in meta_timings]
        summary = {
            "metatile_count": len(durations),
            "duration_ms_sum": sum(durations),
            "duration_ms_min": min(durations),
            "duration_ms_max": max(durations),
            "duration_ms_avg": int(sum(durations) / len(durations)),
            "tiles_written": written_total,
            "wall_ms": int(elapsed * 1000),
        }
        summary_path = Path(audit_dir) / "render_summary.json"
        summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        log(
            "INFO",
            f"Audit render summary: {summary['metatile_count']} metatiles, "
            f"avg {summary['duration_ms_avg']} ms, max {summary['duration_ms_max']} ms "
            f"→ {summary_path}",
        )

    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Render XYZ tiles via PyQGIS metatile loop")
    p.add_argument("--project", required=True, help="Path to .qgz / .qgs")
    p.add_argument(
        "--extent",
        required=True,
        help='Extent as "xmin,xmax,ymin,ymax [EPSG:4326]"',
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
    p.add_argument("--format", default="jpg", choices=["png", "jpg", "jpeg", "PNG", "JPG", "JPEG"])
    p.add_argument("--quality", type=int, default=90, help="JPEG quality")
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
    if not os.path.isfile(args.project):
        log("ERROR", f"Project not found: {args.project}")
        return 1
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
