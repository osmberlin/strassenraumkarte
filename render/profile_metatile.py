#!/usr/bin/env python3
"""
Render one or a few metatiles and print where the time and memory go.

This QGIS build does not expose QgsMapRendererJob.perLayerRenderingTime(),
so layer times come from the layerRenderingStarted / layerRendered signals.
Label time is the gap between renderingLayersFinished and the end of the job.

Examples:
  python3 render/profile_metatile.py \\
      --extent 13.439498,52.472155,13.449776,52.475932 --zoom 17,18,19,20

  python3 render/profile_metatile.py --tile 18/140862/86026 --no-labels

  python3 render/profile_metatile.py --extent ... --zoom 18 --only-layer "water body"

While profiling, log slow SQL in new database sessions (restored on exit):
  --log-slow-sql 200
"""

from __future__ import annotations

import argparse
import atexit
import os
import subprocess
import sys
import threading
import time
from typing import List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from xyz_tiles import (  # noqa: E402
    DB_HOST,
    DB_NAME,
    DB_PORT,
    DB_USER,
    DEFAULT_BACKGROUND,
    MetaTile,
    TileRange,
    format_mib,
    init_render_context,
    iter_metatiles,
    log,
    metatile_extent_3857,
    normalize_tile_format,
    parse_background_color,
    parse_extent,
    process_pss_bytes,
    render_metatile,
    tile_range_for_bbox,
)
from qgis.core import QgsMapSettings  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROJECT = os.path.join(REPO_ROOT, "style", "strassenraumkarte.qgz")


def _psql(sql: str) -> str:
    return subprocess.check_output(
        [
            "psql",
            "-U", DB_USER,
            "-h", DB_HOST,
            "-p", DB_PORT,
            "-d", DB_NAME,
            "-v", "ON_ERROR_STOP=1",
            "-At",
            "-c", sql,
        ],
        text=True,
    ).strip()


def _restore_slow_sql(previous: Optional[str]) -> None:
    if previous:
        safe = previous.replace("'", "''")
        _psql(
            "ALTER DATABASE "
            + _quote_ident(DB_NAME)
            + f" SET log_min_duration_statement = '{safe}'"
        )
    else:
        _psql(
            "ALTER DATABASE "
            + _quote_ident(DB_NAME)
            + " RESET log_min_duration_statement"
        )


def _quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def enable_slow_sql_log(ms: int) -> None:
    """Log statements slower than ms for new sessions. Restored at process exit."""
    previous = _psql(
        "SELECT split_part(cfg, '=', 2) "
        "FROM pg_db_role_setting s "
        "JOIN pg_database d ON d.oid = s.setdatabase "
        "CROSS JOIN LATERAL unnest(s.setconfig) AS cfg "
        "WHERE d.datname = current_database() AND s.setrole = 0 "
        "AND cfg LIKE 'log_min_duration_statement=%' "
        "LIMIT 1"
    )
    _psql(
        "ALTER DATABASE "
        + _quote_ident(DB_NAME)
        + f" SET log_min_duration_statement = '{int(ms)}ms'"
    )
    atexit.register(_restore_slow_sql, previous or None)
    log(
        "INFO",
        f"log_min_duration_statement={int(ms)}ms for new sessions "
        f"(restored to {previous or 'default'} on exit).",
    )


class PeakSampler:
    """Track peak RSS and PSS of this process while a metatile is painting."""

    def __init__(self) -> None:
        self.peak_rss = 0
        self.peak_pss = 0
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._sample()
        self._thread = threading.Thread(target=self._run, name="rss-sampler", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        self._sample()

    def _run(self) -> None:
        while not self._stop.wait(0.2):
            self._sample()

    def _sample(self) -> None:
        rss = _vm_kb("VmRSS:")
        if rss:
            self.peak_rss = max(self.peak_rss, rss * 1024)
        pss = process_pss_bytes(os.getpid())
        if pss:
            self.peak_pss = max(self.peak_pss, pss)


def _vm_kb(key: str) -> Optional[int]:
    try:
        with open("/proc/self/status", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith(key):
                    return int(line.split()[1])
    except OSError:
        return None
    return None


class LayerTimer:
    """Per-layer wall time from renderer signals, plus labeling after layers."""

    def __init__(self, layers: Sequence) -> None:
        self.names = {layer.id(): layer.name() for layer in layers}
        self._starts: dict = {}
        self.ms_by_id: dict = {}
        self.layers_finished_at: Optional[float] = None
        self.label_ms: Optional[float] = None
        self.total_ms: Optional[int] = None

    def attach(self, job) -> None:
        job.layerRenderingStarted.connect(self._start)
        job.layerRendered.connect(self._done)
        job.renderingLayersFinished.connect(self._layers_finished)

    def finish(self, job) -> None:
        self.total_ms = int(job.renderingTime())
        if self.layers_finished_at is not None:
            self.label_ms = max(0.0, (time.perf_counter() - self.layers_finished_at) * 1000.0)
        official = getattr(job, "perLayerRenderingTime", None)
        if not callable(official):
            return
        try:
            rows = official()
        except Exception:  # noqa: BLE001
            return
        if not rows:
            return
        # Prefer the engine's own accounting when this QGIS build exposes it.
        self.ms_by_id = {}
        for row in rows:
            layer = getattr(row, "layer", None)
            ms = getattr(row, "time", None)
            if layer is None or ms is None:
                continue
            self.ms_by_id[layer.id()] = float(ms)
            self.names.setdefault(layer.id(), layer.name())

    def _start(self, layer_id: str) -> None:
        self._starts[str(layer_id)] = time.perf_counter()

    def _done(self, layer_id: str) -> None:
        lid = str(layer_id)
        started = self._starts.pop(lid, None)
        if started is None:
            return
        self.ms_by_id[lid] = self.ms_by_id.get(lid, 0.0) + (time.perf_counter() - started) * 1000.0

    def _layers_finished(self) -> None:
        self.layers_finished_at = time.perf_counter()

    def rows(self) -> List[tuple]:
        ranked = []
        for lid, ms in self.ms_by_id.items():
            if ms <= 0:
                continue
            ranked.append((ms, self.names.get(lid, lid)))
        ranked.sort(reverse=True)
        return ranked


def parse_tile(value: str) -> tuple:
    raw = value.strip().replace(",", "/")
    parts = raw.split("/")
    if len(parts) != 3:
        raise argparse.ArgumentTypeError(f"Expected z/x/y, got {value!r}")
    try:
        z, x, y = (int(p) for p in parts)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Expected z/x/y, got {value!r}") from exc
    if z < 0 or x < 0 or y < 0:
        raise argparse.ArgumentTypeError(f"Tile coordinates must be >= 0: {value}")
    return z, x, y


def parse_zooms(value: str) -> List[int]:
    zooms = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        zooms.append(int(part))
    if not zooms:
        raise argparse.ArgumentTypeError("No zoom levels given")
    return zooms


def metatile_containing(z: int, x: int, y: int, metatile: int, gutter: int) -> MetaTile:
    """Full metatile block on the grid, not clipped down to the single tile."""
    n = 2**z
    gx = (x // metatile) * metatile
    gy = (y // metatile) * metatile
    x1 = min(n - 1, gx + metatile - 1)
    y1 = min(n - 1, gy + metatile - 1)
    tiles = iter_metatiles(TileRange(gx, x1, gy, y1), z, metatile, gutter)
    if not tiles:
        raise ValueError(f"No metatile for z{z}/{x}/{y}")
    return tiles[0]


def collect_profile_metatiles(args: argparse.Namespace) -> List[MetaTile]:
    metas: List[MetaTile] = []
    for z, x, y in args.tile or []:
        metas.append(metatile_containing(z, x, y, args.metatile, args.gutter))
    if args.extent and args.zoom:
        xmin, ymin, xmax, ymax = parse_extent(args.extent)
        cx = (xmin + xmax) / 2.0
        cy = (ymin + ymax) / 2.0
        for z in args.zoom:
            tr = tile_range_for_bbox(cx, cy, cx, cy, z)
            metas.append(
                metatile_containing(z, tr.x0, tr.y0, args.metatile, args.gutter)
            )
    # Same tile can be selected twice; keep the first.
    seen = set()
    unique: List[MetaTile] = []
    for mt in metas:
        key = (mt.z, mt.x0, mt.y0, mt.x1, mt.y1)
        if key in seen:
            continue
        seen.add(key)
        unique.append(mt)
    return unique


def extent_for_scale(args: argparse.Namespace, metas: Sequence[MetaTile]) -> tuple:
    if args.extent:
        return parse_extent(args.extent)
    mt = metas[0]
    rect = metatile_extent_3857(mt)
    # Mid-latitude of the metatile is enough for @mercator_scale.
    from xyz_tiles import ORIGIN_SHIFT
    import math

    def to_lat(y: float) -> float:
        return math.degrees(math.atan(math.sinh(y / ORIGIN_SHIFT * math.pi)))

    def to_lon(x: float) -> float:
        return x / ORIGIN_SHIFT * 180.0

    return (
        to_lon(rect.xMinimum()),
        to_lat(rect.yMinimum()),
        to_lon(rect.xMaximum()),
        to_lat(rect.yMaximum()),
    )


def select_layers(layers: Sequence, needles: Optional[Sequence[str]]) -> list:
    if not needles:
        return list(layers)
    wanted = [n.lower() for n in needles]
    matched = [layer for layer in layers if any(n in layer.name().lower() for n in wanted)]
    return matched


def print_report(mt: MetaTile, timer: LayerTimer, sampler: PeakSampler, out_dir: str) -> None:
    rect = metatile_extent_3857(mt)
    total = timer.total_ms if timer.total_ms is not None else 0
    rows = timer.rows()
    layer_sum = sum(ms for ms, _name in rows)
    label = f"{timer.label_ms:.0f} ms" if timer.label_ms is not None else "n/a"
    print(
        f"\nz{mt.z} metatile x{mt.x0}-{mt.x1} y{mt.y0}-{mt.y1} "
        f"({mt.tile_count} tiles) → {out_dir}",
        flush=True,
    )
    print(
        f"  envelope 3857: {rect.xMinimum():.3f},{rect.yMinimum():.3f},"
        f"{rect.xMaximum():.3f},{rect.yMaximum():.3f}",
        flush=True,
    )
    print(
        f"  total {total} ms   layers {layer_sum:.0f} ms   labeling {label}   "
        f"peak RSS {format_mib(sampler.peak_rss)}   peak PSS {format_mib(sampler.peak_pss)}",
        flush=True,
    )
    print("  ms      layer", flush=True)
    for ms, name in rows:
        print(f"  {ms:7.0f}  {name}", flush=True)


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Profile one or more Straßenraumkarte metatiles.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--project", default=DEFAULT_PROJECT, help="Path to .qgz / .qgs")
    p.add_argument(
        "--extent",
        help='WGS84 "xmin,ymin,xmax,ymax"; with --zoom, render the metatile at the centre',
    )
    p.add_argument(
        "--zoom",
        type=parse_zooms,
        help="Comma-separated zoom levels used with --extent (e.g. 17,18,19,20)",
    )
    p.add_argument(
        "--tile",
        action="append",
        type=parse_tile,
        help="Tile z/x/y whose metatile is rendered (repeatable)",
    )
    p.add_argument("--metatile", type=int, default=8)
    p.add_argument("--gutter", type=int, default=1)
    p.add_argument("--dpi", type=int, default=96)
    p.add_argument("--background", default=DEFAULT_BACKGROUND)
    p.add_argument("--format", default="png", choices=["webp", "png", "jpg", "jpeg"])
    p.add_argument("--quality", type=int, default=95)
    p.add_argument("--out", default="/tmp/srk-profile", help="Tile output directory")
    p.add_argument("--no-labels", action="store_true", help="Disable DrawLabeling")
    p.add_argument(
        "--no-effects",
        action="store_true",
        help="Disable UseAdvancedEffects (opacity, blend modes, effect stacks)",
    )
    p.add_argument(
        "--only-layer",
        action="append",
        default=[],
        help="Render only layers whose name contains this text (repeatable)",
    )
    p.add_argument(
        "--log-slow-sql",
        nargs="?",
        const=200,
        type=int,
        default=None,
        metavar="MS",
        help=(
            "Set log_min_duration_statement for new DB sessions (200 ms if the "
            "flag is given without a value) and restore it on exit"
        ),
    )
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if not args.tile and not (args.extent and args.zoom):
        log("ERROR", "Pass --tile z/x/y and/or --extent with --zoom.")
        return 1
    if args.metatile < 1 or args.gutter < 0:
        log("ERROR", "Invalid --metatile or --gutter.")
        return 1
    metas = collect_profile_metatiles(args)
    if not metas:
        log("ERROR", "No metatiles to render.")
        return 1

    if args.log_slow_sql is not None:
        try:
            enable_slow_sql_log(args.log_slow_sql)
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            log("WARN", f"Could not set log_min_duration_statement: {exc}")
    else:
        log(
            "INFO",
            "Slow SQL is not logged. Pass --log-slow-sql 200 to record "
            "statements slower than 200 ms in the Postgres log.",
        )

    xmin, ymin, xmax, ymax = extent_for_scale(args, metas)
    try:
        _bg_hex, background = parse_background_color(args.background)
    except ValueError as exc:
        log("ERROR", str(exc))
        return 1
    fmt = normalize_tile_format(args.format)
    os.makedirs(args.out, exist_ok=True)

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
        if args.no_labels:
            ctx.base_settings.setFlag(QgsMapSettings.DrawLabeling, False)
            log("INFO", "DrawLabeling off.")
        if args.no_effects:
            ctx.base_settings.setFlag(QgsMapSettings.UseAdvancedEffects, False)
            log("INFO", "UseAdvancedEffects off.")
        layers = select_layers(ctx.layers, args.only_layer)
        if args.only_layer and not layers:
            log("ERROR", f"No visible layer matches {args.only_layer!r}.")
            return 1
        if args.only_layer:
            log("INFO", "Only layers: " + ", ".join(layer.name() for layer in layers))

        for mt in metas:
            timer = LayerTimer(layers)
            sampler = PeakSampler()

            def before(job, timer=timer, sampler=sampler) -> None:
                timer.attach(job)
                sampler.start()

            def after(job, timer=timer, sampler=sampler) -> None:
                sampler.stop()
                timer.finish(job)

            render_metatile(
                ctx.base_settings,
                layers,
                mt,
                args.out,
                fmt,
                args.quality,
                ctx.crs_3857,
                background,
                before_start=before,
                after_finish=after,
                wait_events=True,
            )
            print_report(mt, timer, sampler, args.out)
    finally:
        ctx.app.exitQgis()
    return 0


if __name__ == "__main__":
    sys.exit(main())
