# Rust renderer speed iterations

Measured **2026-08-01** after implementing [rust_renderer_speedups](../../.cursor/plans/rust_renderer_speedups_b7184fc3.plan.md).  
Host: Darwin arm64 10 CPUs · PostGIS `localhost:5433` · bbox `13.3958,52.4243,13.4874,52.4849`.

Baseline before this track (1 thread, style-iterate full-approx): z18–z20 **~891 s** vs QGIS **1568 s** (~**1.8×**).

## What landed

| Iteration | Change |
| --- | --- |
| 0 Profile | `--profile` → `stages` in `timing.json` (`sql` / `paint` / `shapeburst` / `shadow` / `encode`) |
| 1 Workers | `--workers N` (default 1; env `SRK_WORKERS`); one Postgres client per thread; shared texture/tree catalogs |
| 2 Shapeburst | Bbox-limited + batch helpers in `paint.rs` (building path uses batched drop-shadow; shapeburst optional) |
| 3 SQL | Lighter `WHERE geom && env`; clip helpers kept `ST_MakeValid` (dropping it at z≥18 caused WKB EOF skips) |
| 4 Metatile | Deferred — `--metatile` accepts only `1` for now |

## Headline result (target was ≥5× vs QGIS)

| Engine | Scope | Workers | Tiles | Wall | ms/tile | vs QGIS z18–20 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| QGIS full style | z18–20 | 2 + metatile 8 | 102 225 | **1568 s** | ~15.3 | 1.0× |
| Rust full-approx (prior) | z18–20 | 1 | 102 225 | **~891 s** | ~8.7 | **1.8×** |
| **Rust full-approx (now)** | z18–20 | **8** | 102 225 | **223 s (~3.7 min)** | **2.18** | **~7.0×** |

Artefact: `runs/bench-speed-w8-z18-20/rust/timing.json`.

## Worker scaling (z18 only, 4964 tiles)

| Workers | Wall | ms/tile | vs workers=1 | vs QGIS z18 (55.1 s) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 41.7 s | 8.40 | 1.0× | 1.3× |
| 8 | **10.7 s** | **2.16** | **~3.9×** | **~5.1×** |

Runs: `bench-speed-w1-z18/`, `bench-speed-w8-z18/`.

## Profile notes (workers=8, z18–20)

Stage counters are **summed across worker threads** (CPU-time-ish), not calendar wall:

| Stage | Summed ms | Share of stage sum |
| --- | ---: | ---: |
| sql | 814 116 | ~70% |
| encode | 191 601 | ~16% |
| paint | 123 716 | ~11% |
| shadow | 32 000 | ~3% |
| shapeburst | 0 | — |

Under 8 workers the renderer is **Postgres-bound**. Next wins: connection/query batching, prepared statements, metatile fetch amortization — not more CPU threads alone.

## How to re-bench

```bash
cd rust/srk-render && cargo build --release

# fair vs QGIS z18–20
./target/release/srk-render \
  --bbox 13.3958,52.4243,13.4874,52.4849 \
  --zmin 18 --zmax 20 --layers full-approx \
  --out /tmp/srk-speed --format png --workers 8 --quiet --timing-json --profile

# harness default now passes workers=8
WORKERS=8 ./audit/tile-regression/scripts/bench-large-fullapprox.sh
```

## Verdict

Parallel tile workers deliver the plan goal: **~7× wall vs production-shaped QGIS** on z18–z20 (was ~1.8× single-threaded). Visual parity work remains separate; this track does not claim style completeness.
