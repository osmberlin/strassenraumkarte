# Rust renderer speed iterations

Measured **2026-08-01** on Darwin arm64 10 CPUs · PostGIS `localhost:5433` · bbox `13.3958,52.4243,13.4874,52.4849`.

## Live farm headline (WebP q90)

Production output is **lossy WebP** (default). PNG is harness-only. JPG exists for format parity but is not farm-ready (slow `image` crate encode).

Artefact: `runs/bench-speedups-20260801-201757/` (z18–z20, 102 225 tiles, workers=8).

| Config | Wall | ms/tile | vs QGIS (1568 s) | Notes |
| --- | ---: | ---: | ---: | --- |
| **mt1 gutter0 (farm default)** | **78.8 s** | **0.77** | **~20×** | Max throughput; no neighbour bleed |
| mt4 gutter1 | 93.0 s | 0.91 | ~17× | Edge bleed + moderate amortise |
| mt8 gutter1 | 96.2 s | 0.94 | ~16× | QGIS-shaped metatile+gutter |
| Prior baseline (webp, pre this pass) | 82.5 s | 0.81 | ~19× | Codec bench; no metatile API |

**Cite ~79 s / ~20× QGIS** for live WebP capacity (`--metatile 1 --gutter 0 --workers 8`).

### Metatile lesson (this bbox)

| Zoom / density | Winner | Why |
| --- | --- | --- |
| z18 only (dense) | **mt8 g1 ≈ 6.2 s** vs mt1 g1 ≈ 25 s | Amortises SQL/paint; gutter cost shared |
| z18–z20 (sparse z20) | **mt1 g0 ≈ 79 s** beats mt8 g1 ≈ 96 s | Per-tile empty early-out beats painting 10×10 metas that contain a few hits |

Use large metatile when the grid is dense; keep mt1 (+ optional gutter1 for seam parity) when many tiles are empty.

### Codec sizes (unchanged intent)

From `bench-codecs-20260801-194104` (same bbox/zooms): WebP ~36 MiB · JPG ~275 MiB · PNG ~453 MiB. Quality at q90 ≈ visually lossless vs PNG under pixelmatch threshold 0.1.

## What landed

| Pass | Change | Effect |
| --- | ---: | ---: |
| 0–3 | Profile, workers, shapeburst helpers, light WHERE | Earlier track |
| **4 Metatile N** | True N×N paint + crop (QGIS `iter_metatiles`) | Wins on dense z18; mixed on sparse z20 |
| 5 Empty early-out | EXISTS OR probe | Big on sparse z20 (per metatile) |
| 6 Prepared stmts | Per-worker `PreparedCache` | Cuts parse/plan |
| 7 Live codecs | webp/jpg/png + `bench-codecs.sh` | WebP live default |
| **8 WebP method=1** | `encode_advanced` (libwebp method 0–6) | Small wall help; encode still large stage |
| **9 UNION ALL** | Tried one polygon+line round-trip | **Reverted** — ~2× SQL on local Postgres |
| **10 Trees z&lt;17** | Skip EXISTS + paint (MapLibre minzoom) | Style-aligned; no z18–20 effect |
| Gutter default **0** | `--gutter 1` for QGIS-like bleed | Farm speed vs seam parity |

## Profile (workers=8, z18–z20, WebP)

| Stage (∑ ms) | Prior webp ~82 s | **Farm mt1 g0 ~79 s** | mt8 g1 ~96 s |
| --- | ---: | ---: | ---: |
| sql | 98 430 | 137 723 | **7 203** |
| paint | 116 302 | **13 208** | 44 601 |
| shadow | 24 929 | 41 166 | 264 563 |
| encode | 239 792 | 245 799 | 378 472 |

Metatile collapses SQL; shadow/encode grow with buffer size. Empty early-out + mt1 still wins overall on this sparse high-zoom set.

## Next ideas

1. **Zoom-aware metatile** — e.g. mt8 below z19, mt1 at z20 (or density heuristic).
2. **Faster JPEG** — only if JPG must ship (`mozjpeg` / libjpeg-turbo).
3. **Remote-DB UNION** — may win when round-trip latency ≫ local socket.
4. **Blank-tile encode cache** — reuse one encoded empty WebP for early-out cores.

## How to re-bench

```bash
cd rust/srk-render && cargo build --release

# Live farm (default gutter 0)
./target/release/srk-render \
  --bbox 13.3958,52.4243,13.4874,52.4849 \
  --zmin 18 --zmax 20 --layers full-approx \
  --out /tmp/srk-speed --format webp --quality 90 \
  --metatile 1 --gutter 0 --workers 8 --quiet --timing-json --profile

# QGIS-shaped parity render
./target/release/srk-render ... --metatile 8 --gutter 1
```

## Verdict

**Live farm WebP:** **~79 s / ~20× QGIS** on z18–z20 with 8 workers (mt1, gutter 0). Metatile 4/8 + gutter 1 stays ~17× and is better for dense zooms / edge bleed. UNION ALL not worth it on local PostGIS. Visual parity remains a separate track.
