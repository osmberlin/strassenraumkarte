# Rust renderer speed iterations

Measured **2026-08-01** on Darwin arm64 10 CPUs · PostGIS `localhost:5433` · bbox `13.3958,52.4243,13.4874,52.4849`.

Plan: [rust_renderer_speedups](../../.cursor/plans/rust_renderer_speedups_b7184fc3.plan.md).

## Headline (z18–z20, 102 225 tiles)

| Engine | Workers | Format | Wall | ms/tile | vs QGIS |
| --- | ---: | --- | ---: | ---: | ---: |
| QGIS full style | 2 + metatile 8 | jpg | **1568 s** | ~15.3 | 1.0× |
| Rust (pre-speed track) | 1 | png | ~891 s | ~8.7 | 1.8× |
| Rust + workers | 8 | png | 223 s | 2.18 | 7.0× |
| **Rust + workers + prep + empty early-out** | **8** | **png** | **65.8 s (~1.1 min)** | **0.64** | **~24×** |
| Rust + workers + prep + empty early-out | 8 | webp q90 | 105 s | 1.03 | ~15× |

Artefacts: `runs/bench-speed-w8-z18-20-prep/`, `runs/bench-speed-w8-z18-20-webp/`.

**Note:** WebP is slower to *encode* than PNG with the current `webp` crate (~2.5× encode stage time). Prefer `--format png` for throughput benches; WebP for smaller tiles on disk/CDN.

## What landed

| Pass | Change | Effect |
| --- | --- | --- |
| 0 Profile | `--profile` stage timers | Identified SQL-bound under workers |
| 1 Workers | `--workers N` / `SRK_WORKERS` | ~3.9× wall on z18 (1→8) |
| 2 Shapeburst | Bbox/batch helpers | Ready; building path uses shadow batch |
| 3 SQL light WHERE | `geom && env` only | Modest |
| 4 Metatile | Deferred (`--metatile` = 1 only) | — |
| **5 Empty early-out** | One `EXISTS` OR probe; skip paint on empty tiles | Big on sparse z20 |
| **6 Prepared stmts** | Per-worker `PreparedCache` | Cuts parse/plan overhead |

## Worker scaling (z18, 4964 tiles, png)

| Workers | Wall | ms/tile | Notes |
| ---: | ---: | ---: | --- |
| 1 | 41.7 s | 8.40 | before prep/early-out |
| 8 | 10.7 s | 2.16 | workers only |
| **8 + prep + early-out** | **~5.0 s** | **~1.0** | smoke after pass 5–6 |

## Profile evolution (workers=8, z18–z20, summed across threads)

| Stage | After workers (png) | After prep+early-out (png) |
| --- | ---: | ---: |
| sql | 814 116 (~70%) | **71 685 (~21%)** |
| encode | 191 601 (~16%) | **143 384 (~42%)** |
| paint | 123 716 (~11%) | 104 078 (~30%) |
| shadow | 32 000 | 24 414 |

SQL is no longer dominant. **Encode + paint** are the next bottlenecks for dense tiles; empty early-out already removed most empty-tile SQL.

## Next ideas (not done this pass)

1. **Metatile N=4/8** — amortize paint/shadow like QGIS (still deferred).
2. **Faster encode** — tune WebP (or stick to PNG for render farms); optional JPEG via `image` crate.
3. **Multi-layer `UNION ALL` fetch** — one round-trip for landuse+highway+buildings when tile is non-empty.
4. **Skip texture/tree work at low zoom** if style allows (visual trade-off).

## How to re-bench

```bash
cd rust/srk-render && cargo build --release

./target/release/srk-render \
  --bbox 13.3958,52.4243,13.4874,52.4849 \
  --zmin 18 --zmax 20 --layers full-approx \
  --out /tmp/srk-speed --format png --workers 8 --quiet --timing-json --profile
```

## Verdict

From ~1.8× to **~24×** vs production-shaped QGIS on z18–z20 (png, 8 workers, prepared statements + empty-tile early-out). Visual parity remains a separate track.
