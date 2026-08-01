# QGIS render exploration results (2026-08-01)

Starter bbox `13.4132,52.4715,13.4312,52.4821`, z15–18 (~278 tiles, 10 metatiles).
Raw run: `audit/render-explore/20260801T131243Z/` (gitignored).

| Case | Wall | vs baseline | Notes |
| --- | ---: | ---: | --- |
| baseline (1 worker, no fonts) | **66.4 s** | 1.00× | Open Sans alias warning (~43 ms once) |
| fonts (`render/fonts` Open Sans) | **64.4 s** | 0.97× | Warning gone; wall-time ≈ noise |
| workers=2 (+ fonts) | **39.2 s** | **0.59×** | Best on this AOI |
| workers=4 (+ fonts) | **39.7 s** | 0.60× | No gain vs 2 (only 10 metatiles; higher avg/max metatile ms) |

## Takeaways

1. **Parallel metatile processes help** — ~**1.7×** wall-time with `--workers 2` here. PyQGIS is process-parallel only.
2. **4 workers did not beat 2** on this tiny job (startup + DB contention dominate when metatile count is small).
3. **Bundled Open Sans** is worth keeping for correct labels / quieter logs; not a material speedup.
4. **`QT_IMAGEIO_MAXALLOC=0`** in `qgis_env.sh` for denser renders (512 MB rejects on large bbox); not measurable here.

## How to reproduce

```bash
./audit/render-explore/run-explore.sh
# or manually:
./render/render_tiles.sh --bbox 13.4132,52.4715,13.4312,52.4821 --zmin 15 --zmax 18 --workers 2
```

## Next steps

- ~~Retest `--workers 2–4` on the **large** bbox~~ → see [LARGE_WORKERS.md](./LARGE_WORKERS.md) (z16: ~1.6× with 2 workers; 4≈2).
- ~~Tile equivalence (SSIM)~~ → see `audit/tile-compare/RESULTS.md` (PASS).
- Profile layer cost / metatile size at z18 (still the big city-scale pain).
