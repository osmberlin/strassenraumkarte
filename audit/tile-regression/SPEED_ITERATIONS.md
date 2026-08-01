# Rust renderer speed iterations

Measured **2026-08-01** on Darwin arm64 10 CPUs · PostGIS `localhost:5433` · bbox `13.3958,52.4243,13.4874,52.4849`.

Plan: [rust_renderer_speedups](../../.cursor/plans/rust_renderer_speedups_b7184fc3.plan.md).

## Live farm codecs (what we optimize for)

Production-shaped output is **lossy WebP or JPG** (q90), not PNG. PNG stays for the pixelmatch harness only.

Codec compare: `./audit/tile-regression/scripts/bench-codecs.sh`  
Artefact: `runs/bench-codecs-20260801-194104/summary.json` (z18–z20, 102 225 tiles, workers=8, q90).

| Format | Role | Wall | ms/tile | vs QGIS (1568 s jpg) | Disk | Avg/tile | Encode stage (∑) | Quality vs PNG\* |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **webp q90** | **live default** | **82.5 s** | **0.81** | **~19×** | **35.6 MiB** | **365 B** | 240 k ms | ~0.001% mean |
| jpg q90 | live / QGIS-like | 643 s | 6.29 | ~2.4× | 275 MiB | 2 816 B | **4.5 M ms** | ~0.000% mean |
| png | harness / lossless ref | 70.4 s | 0.69 | ~22× | 453 MiB | 4 645 B | 154 k ms | — |

\*Sample of 10 dense tiles, `pixelmatch` threshold 0.1 after decode. Both lossy codecs look essentially identical to PNG at q90 for this metric; size is the differentiator.

**Takeaways**

- **WebP is the live number to cite:** ~19× QGIS wall, ~12.7× smaller than PNG, ~7.7× smaller than our JPG output.
- **JPG encode via the `image` crate is not farm-ready** here (~8× slower wall than WebP; encode stage dominates). Fine for format parity checks; do not use as the throughput target until swapped to a faster JPEG backend (or stick to WebP).
- Earlier “optimize PNG benches” framing was wrong for live capacity — use `--format webp` (or the codec script) when measuring farm speed.

Sample tile sizes (lossy vs same PNG):

| Tile | PNG | WebP (% of PNG) | JPG (% of PNG) |
| --- | ---: | ---: | ---: |
| 18/140845/86022 | 78 157 | 12 024 (15%) | 20 525 (26%) |
| 19/281690/172045 | 72 837 | 8 666 (12%) | 16 150 (22%) |
| 20/563376/344090 | 35 570 | 3 006 (8%) | 8 354 (24%) |

## Historical PNG ladder (harness codec)

Same bbox/zooms; useful for SQL/paint regression only — **not** live farm capacity.

| Engine | Workers | Format | Wall | ms/tile | vs QGIS |
| --- | ---: | --- | ---: | ---: | ---: |
| QGIS full style | 2 + metatile 8 | jpg | **1568 s** | ~15.3 | 1.0× |
| Rust (pre-speed track) | 1 | png | ~891 s | ~8.7 | 1.8× |
| Rust + workers | 8 | png | 223 s | 2.18 | 7.0× |
| Rust + workers + prep + empty early-out | 8 | png | 65.8–70.4 s | ~0.64–0.69 | ~22–24× |
| **Rust + workers + prep + empty early-out** | **8** | **webp q90** | **82.5 s** | **0.81** | **~19×** |

## What landed

| Pass | Change | Effect |
| --- | ---: | ---: |
| 0 Profile | `--profile` stage timers | Identified SQL-bound under workers |
| 1 Workers | `--workers N` / `SRK_WORKERS` | ~3.9× wall on z18 (1→8) |
| 2 Shapeburst | Bbox/batch helpers | Ready; building path uses shadow batch |
| 3 SQL light WHERE | `geom && env` only | Modest |
| 4 Metatile | Deferred (`--metatile` = 1 only) | — |
| **5 Empty early-out** | One `EXISTS` OR probe; skip paint on empty tiles | Big on sparse z20 |
| **6 Prepared stmts** | Per-worker `PreparedCache` | Cuts parse/plan overhead |
| **7 Live codecs** | `--format webp\|jpg\|png` + `bench-codecs.sh` | WebP live default; JPG for compare |

## Worker scaling (z18, 4964 tiles, png)

| Workers | Wall | ms/tile | Notes |
| ---: | ---: | ---: | --- |
| 1 | 41.7 s | 8.40 | before prep/early-out |
| 8 | 10.7 s | 2.16 | workers only |
| **8 + prep + early-out** | **~5.0 s** | **~1.0** | smoke after pass 5–6 |

## Profile evolution (workers=8, z18–z20, summed across threads)

| Stage | After workers (png) | After prep+early-out (png) | Live webp q90 |
| --- | ---: | ---: | ---: |
| sql | 814 116 (~70%) | **71 685 (~21%)** | 98 430 |
| encode | 191 601 (~16%) | **143 384 (~42%)** | **239 792** |
| paint | 123 716 (~11%) | 104 078 (~30%) | 116 302 |
| shadow | 32 000 | 24 414 | 24 929 |

On WebP, encode is the largest summed stage; still ~19× QGIS wall overall.

## Next ideas (not done this pass)

1. **Metatile N=4/8** — amortize paint/shadow like QGIS (still deferred).
2. **Faster live encode** — WebP is already acceptable; optional faster JPEG (`mozjpeg`/libjpeg-turbo) only if JPG must ship.
3. **Multi-layer `UNION ALL` fetch** — one round-trip for landuse+highway+buildings when tile is non-empty.
4. **Skip texture/tree work at low zoom** if style allows (visual trade-off).

## How to re-bench

```bash
# Live codecs (preferred)
./audit/tile-regression/scripts/bench-codecs.sh

# Single live run
cd rust/srk-render && cargo build --release
./target/release/srk-render \
  --bbox 13.3958,52.4243,13.4874,52.4849 \
  --zmin 18 --zmax 20 --layers full-approx \
  --out /tmp/srk-speed --format webp --quality 90 \
  --workers 8 --quiet --timing-json --profile
```

## Verdict

**Live farm:** WebP q90 @ 8 workers ≈ **83 s / ~19× QGIS** on z18–z20, **~36 MiB** vs **~275 MiB** JPG / **~453 MiB** PNG. JPG is available for size/quality compare but current encode is too slow to be the capacity metric. Visual parity remains a separate track.
