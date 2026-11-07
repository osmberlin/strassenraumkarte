# Rust pipeline WebP migration

**Date:** 2026-08-01  
**Scope:** `srk-render` output codec only (paint parity unchanged).  
**Default:** `--format webp --quality 90` (lossy). PNG retained for the tile-regression harness (`--format png`).

## Confirmation (before adopting)

Same pixels, dense intersection tile `17/70422/43011` (full-approx), encoded by `srk-render`:

| Codec | Bytes | vs PNG |
| --- | ---: | ---: |
| PNG (lossless) | 98 285 | — |
| WebP q90 | 18 644 | **−81.0%** |

Stratified sample of **120** tiles from the previous large-bbox PNG tree, re-encoded with `cwebp`:

| Codec | Sample avg | vs PNG |
| --- | ---: | ---: |
| PNG | 13 270 B | — |
| WebP lossless | 7 872 B | **−40.7%** |
| WebP q90 | 1 417 B | **−89.3%** |

**Verdict:** WebP is smaller. Lossy q90 matches the production intent of QGIS JPEG q90 and yields the large savings — adopted as the pipeline default. Harness stays on PNG so pixelmatch remains bit-stable.

Full z18–z20 live compare (webp vs jpg vs png: wall, disk, quality): [`SPEED_ITERATIONS.md`](SPEED_ITERATIONS.md) and `runs/bench-codecs-*/summary.json` via `scripts/bench-codecs.sh`.

## Previous full-area PNG baseline (stored)

Source: `runs/bench-large-fullapprox-20260801-171946/rust`  
Machine-readable: [`webp-prev-png-baseline.json`](webp-prev-png-baseline.json)

| Parameter | Value |
| --- | --- |
| Bbox | `13.3958,52.4243,13.4874,52.4849` |
| Zooms | z15–z20 |
| Tiles | **103 915** |
| Format | PNG |
| **Total size (sum of file bytes)** | **866 481 021 B (826.3 MiB)** |
| Avg / tile | 8 338 B |

| z | Tiles | Total | Avg |
| ---: | ---: | ---: | ---: |
| 15 | 90 | 1.0 MiB | 11 351 |
| 16 | 342 | 3.4 MiB | 10 505 |
| 17 | 1 258 | 11.7 MiB | 9 770 |
| 18 | 4 964 | 42.6 MiB | 9 006 |
| 19 | 19 564 | 159.0 MiB | 8 520 |
| 20 | 77 697 | 608.6 MiB | 8 214 |

## Full-area WebP run (adopted pipeline)

Source: `runs/bench-large-fullapprox-20260801-175340/rust`  
Machine-readable: [`webp-full-run.json`](webp-full-run.json)

| Parameter | Value |
| --- | --- |
| Bbox / zooms | same as PNG baseline |
| Tiles | **103 915** |
| Format | WebP q90 |
| **Total size (sum of file bytes)** | **82 180 770 B (78.4 MiB)** |
| Avg / tile | 791 B |
| Wall (internal) | 773.8 s (~12.9 min), 7.4 ms/tile |

| z | Tiles | Total | Avg |
| ---: | ---: | ---: | ---: |
| 15 | 90 | 0.1 MiB | 1 573 |
| 16 | 342 | 0.4 MiB | 1 348 |
| 17 | 1 258 | 1.4 MiB | 1 139 |
| 18 | 4 964 | 4.5 MiB | 954 |
| 19 | 19 564 | 15.5 MiB | 833 |
| 20 | 77 697 | 56.4 MiB | 761 |

### Size delta (PNG → WebP)

| Metric | PNG (prev) | WebP (this run) | Delta |
| --- | ---: | ---: | ---: |
| Total | **826.3 MiB** | **78.4 MiB** | **−747.9 MiB (−90.5%)** |
| Avg / tile | 8 338 B | 791 B | **−90.5%** |

Sizes above are **logical** (sum of `st_size`). On APFS, `du` for ~104k tiny files is higher because each file consumes at least one allocation block — that overhead is unrelated to the codec.

## Pipeline changes

| Surface | Change |
| --- | --- |
| `srk-render` | Default `--format webp`; `--quality` (default 90); `--format png` still supported |
| `bench-large-fullapprox.sh` | Writes WebP q90 |
| Vite `/raster-rust/` | Serves `.webp` (falls back to png/jpg) |
| Compare UI | Requests `/raster-rust/{z}/{x}/{y}.webp` |
| Regression suites | Unchanged — still `--format png` for pixelmatch |

## Dependency

- Rust crate `webp` 0.3 (links `libwebp`; Homebrew `webp` / `pkg-config`)

## Re-run

```bash
./audit/tile-regression/scripts/bench-large-fullapprox.sh
# single tile
rust/srk-render/target/release/srk-render \
  --tiles 17/70422/43011 --layers full-approx \
  --out /tmp/srk-webp --format webp --quality 90
```
