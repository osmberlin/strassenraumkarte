# Large-bbox full-style timing — Rust `full-approx` vs QGIS

Measured **2026-08-01** on Darwin arm64 (10 CPUs), PostGIS `localhost:5433`.

This report compares **full-style / full-approx only**. Highway-area isolate benches are out of scope.

## Fixture

| Parameter | Value |
| --- | --- |
| Bbox (WGS84) | `13.3958,52.4243,13.4874,52.4849` (large / Neukölln-ish) |
| Zooms | **z15–z20** (QGIS project defaults) |
| Tiles | **103 915** |
| Rust run | `runs/bench-large-fullapprox-20260801-162831/` |
| Preview | Vite `/raster-rust/` → `runs/latest-rust` (symlink to that run) |
| QGIS tiles | `render/tiles/` (same bbox/zooms; jpg, metatile 8, workers 2) |

## Headline

| Engine | Scope | Tiles | Wall | ms/tile |
| --- | --- | ---: | ---: | ---: |
| **srk-render** | `full-approx` PNG, 1 thread | 103 915 | **904 s (~15.1 min)** | **8.7** |
| **QGIS** (this fill) | full style JPG, metatile 8, workers 2 | z18–z20 = 102 225 | **1568 s (~26.1 min)** | **~15.3** |

## Rust per zoom

| z | Tiles | Wall | ms/tile |
| ---: | ---: | ---: | ---: |
| 15 | 90 | 0.5 s | 5.7 |
| 16 | 342 | 1.7 s | 5.1 |
| 17 | 1 258 | 11.5 s | 9.1 |
| 18 | 4 964 | 31.3 s | 6.3 |
| 19 | 19 564 | 134.1 s | 6.9 |
| 20 | 77 697 | 725.2 s | 9.3 |
| **Σ** | **103 915** | **904.3 s** | **8.7** |

Artefact: `runs/bench-large-fullapprox-20260801-162831/rust/timing.json`.

## QGIS full style (same bbox) — measured fill

Re-rendered into `render/tiles/` so the compare UI has matching coverage (no isolate).

| z | Tiles | Wall (`time -p`) | ms/tile | Notes |
| ---: | ---: | ---: | ---: | --- |
| 15–17 | 90+342+1 258 | *(pre-existing; not re-timed)* | — | Already complete before this pass |
| 18 | 4 964 | **55.1 s** | **11.1** | metatile 8, workers 2, jpg |
| 19 | 19 564 | **181.8 s** | **9.3** | same |
| 20 | 77 697 | **1330.7 s (~22.2 min)** | **17.1** | same |

**QGIS z18–z20 wall sum:** 55.1 + 181.8 + 1330.7 = **1567.6 s (~26.1 min)** for 102 225 tiles (~15.3 ms/tile average).

### Matched speedup (same bbox, timed zooms)

| Zoom | Rust wall | QGIS wall | Speedup (QGIS/Rust) |
| ---: | ---: | ---: | ---: |
| 18 | 31.3 s | 55.1 s | **~1.8×** |
| 19 | 134.1 s | 181.8 s | **~1.4×** |
| 20 | 725.2 s | 1330.7 s | **~1.8×** |
| **18–20** | **890.6 s** | **1567.6 s** | **~1.8×** |

## Context (older full-style numbers — not this run)

| Source | Bbox | Zooms | Tiles | Wall | ms/tile |
| --- | --- | --- | ---: | ---: | ---: |
| Starter full style (bench) | starter | 15–18 | 278 | 92.2 s | 332 |
| Starter historical audit | starter | 15–18 | 278 | 62.3 s | 224 |
| Large bbox audit (killed) | large | 15–18 partial | 1 852 | 47.4 min | ~1 540 |

Those starter numbers used a smaller area and (for the 332 ms/tile bench) a colder / metatile-1-ish path. The **large-bbox z18–z19 fill above** is the fairer production-shaped compare (metatile 8 + workers 2).

## Caveats (read before citing speedups)

1. **Style depth** — QGIS paints labels, SVG furniture, RasterFill textures, full effect stacks. Rust `full-approx` is landuse → water → roads → buildings (+ soft shadow) → trees. Throughput is not parity.
2. **Parallelism** — QGIS: 2 workers + metatile 8. Rust now supports `--workers N` (see [`SPEED_ITERATIONS.md`](SPEED_ITERATIONS.md)).
3. **Format** — Rust PNG vs QGIS JPG (encode cost differs).
4. **Metatile** — QGIS amortizes project/paint over 8×8 tiles; Rust still paints one 256² tile at a time (metatile deferred).
5. **Coverage** — Tile counts match at every zoom (103 915 each). Compare UI serves both from Vite.

## Speed iterations (2026-08-01)

After `--workers 8` + SQL WHERE lightening + profile tooling: **z18–z20 wall 223 s** vs QGIS **1568 s** → **~7.0×** (was ~1.8× at 1 thread). Full write-up: [`SPEED_ITERATIONS.md`](SPEED_ITERATIONS.md).

## Preview / clean compare

1. Rust tiles: `audit/tile-regression/runs/latest-rust` → large-bbox full-approx z15–z20 (**complete**).
2. QGIS tiles: `render/tiles` z15–z20 (**complete**, same bbox).
3. Compare UI (Vite already prefers `bench-large-fullapprox-*` / `RUST_TILES_ROOT`):

```bash
cd vector && RUST_TILES_ROOT=../audit/tile-regression/runs/latest-rust bun run dev
```

Open e.g.  
`http://127.0.0.1:5177/?compare=1&location=intersection&mode=side-by-side&panes=qgis,rust,vector`  
and zoom 15–20 — both raster panes resolve tiles across the large bbox (including locations that were blank on the old starter-only Rust set).

## Re-run

```bash
./audit/tile-regression/scripts/bench-large-fullapprox.sh
# optional: also refresh QGIS render/tiles for the same bbox/zooms
./audit/tile-regression/scripts/bench-large-fullapprox.sh --also-qgis
```

## Verdict (performance only)

**Updated 2026-08-01 (speed iterations):** with `--workers 8`, Rust full-approx z18–z20 finishes in **~3.7 minutes** vs QGIS **~26 minutes** on the same bbox → **~7×**. See [`SPEED_ITERATIONS.md`](SPEED_ITERATIONS.md).

Earlier single-thread full z15–z20 (~15 min, ~1.8× vs QGIS on z18–z20) remains a useful baseline for “one core” comparisons.