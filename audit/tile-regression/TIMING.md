# Starter-bbox render timing (Rust vs QGIS)

> **Prefer the large-bbox full-style report:** [`LARGE_BBOX_TIMING.md`](LARGE_BBOX_TIMING.md)  
> (103 915 tiles, z15–z20, `full-approx` vs QGIS full style — no highway_area isolate).

Measured **2026-08-01** on the docker starter bbox. Re-run with:

```bash
./audit/tile-regression/scripts/bench-bbox.sh
```

Latest artefacts: [`runs/bench-20260801-153201/summary.json`](runs/bench-20260801-153201/summary.json).

## Fixture

| Parameter | Value |
| --- | --- |
| Bbox (WGS84) | `13.4132,52.4715,13.4312,52.4821` |
| Zooms | z15–z18 |
| Tiles | **278** (same list for Rust and QGIS isolate) |
| Host | Darwin 25.5.0 arm64, 10 CPUs |
| DB | localhost:5433 `strassenraumkarte` |
| Format | PNG (both engines) |

## Results

| Engine | Scope | Tiles | wall_ms | ms/tile | Notes |
| --- | --- | ---: | ---: | ---: | --- |
| **srk-render** | `highway_area` isolate | 278 | **628** | **2.26** | Internal timer; 880 ms external (`time -p`) |
| **QGIS** | `highway_area` isolate | 278 | **35 580** | **128.0** | `--metatile 1 --gutter 1 --workers 1`; same `--tiles` list |
| QGIS (today) | Full style | 278 | 92 210 | 331.7 | `--metatile 8`, all layers; context only |
| QGIS (historical) | Full style | 278 | 62 302 | 224.1 | `audit/runs/20260801T113021Z_berlin-starter-clean`; step 67 495 ms |

### Primary fair comparison

**Rust `highway_area` vs QGIS `highway_area` isolate** — same 278 tiles, PNG, harness metatile mode for QGIS.

| Metric | Value |
| --- | ---: |
| Speedup (QGIS wall / Rust internal) | **~57×** |
| Speedup (QGIS wall / Rust external wall) | **~40×** |

Rust is faster by two orders of magnitude on this slice, but it paints only SimpleFill symbology for one layer — no effects, labels, SVG, or compositing.

### Full-style QGIS (context only)

Not apples-to-apples with Rust today:

- Historical audit (**62.3 s** render wall, 67.5 s step) used the production metatile-8 pipeline on the same bbox/tile count.
- Today's re-run (**92.2 s**, PNG, workers 1) is slower — likely PNG encode vs historical JPEG default, single worker, and cold QGIS startup in the bench script. Order-of-magnitude (~1 min) still holds.

Rust does **not** replace full QGIS style rendering yet.

## Visual parity (timing ≠ done)

Smoke suite on the same bbox (12 tiles, z15–18, `highway_area` isolate): mean pixelmatch **0.079%**, max **0.203%** — see [`REPORT.md`](REPORT.md) and gallery [`runs/20260801-172219-smoke/index.html`](runs/20260801-172219-smoke/index.html). Timing numbers measure throughput on a style slice, not migration readiness.

## Caveats

1. **Scope** — Rust: one layer, class-fill rules only. QGIS isolate still runs the full Qt/QGIS paint stack for that layer (rule evaluation, clipping, rasterization).
2. **Metatile** — Fair compare uses per-tile QGIS (`metatile 1`). Production uses `metatile 8` (fewer render passes, different label/texture phase — see [`RENDER_MODE.md`](RENDER_MODE.md)).
3. **Connection overhead** — Rust holds one Postgres connection; QGIS per-tile path may pay project/layer setup per metatile.
4. **Release build** — `cargo build --release` for Rust; PyQGIS uses system QGIS 3.x.
5. **Tile list** — Enumerated from bbox with Web Mercator math matching `render/xyz_tiles.py` / `srk-render --bbox`.

## CLI additions

`srk-render` now accepts `--bbox xmin,ymin,xmax,ymax` with `--zmin` / `--zmax` (defaults 15/18) as an alternative to `--tiles`. Writes `timing.json` under `--out` and prints a one-line summary.

```bash
./rust/srk-render/target/release/srk-render \
  --bbox 13.4132,52.4715,13.4312,52.4821 \
  --zmin 15 --zmax 18 \
  --layers highway_area \
  --out /tmp/srk-bench-rust \
  --format png --quiet
```

## Artefacts

| Path | Contents |
| --- | --- |
| `runs/bench-20260801-153201/tiles.txt` | 278 `z/x/y` lines |
| `runs/bench-20260801-153201/rust/timing.json` | Rust internal timing |
| `runs/bench-20260801-153201/qgis-highway_area/timing.json` | QGIS isolate timing |
| `runs/bench-20260801-153201/qgis-full-style-timing.json` | Full-style re-run today |
| `runs/bench-20260801-153201/summary.json` | Combined summary |
