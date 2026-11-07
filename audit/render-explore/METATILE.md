# Metatile / gutter exploration (2026-08-01)

**BBox:** starter `13.4132,52.4715,13.4312,52.4821` (DB re-prepped to starter extract)  
**Zoom:** **18 only** (196 tiles) — full z15–18 on the large extract was multi-hour per case  
**Workers:** 2  
**Raw:** `audit/render-explore/20260801T143148Z_metatile/` (gitignored)

| Case | Metatile | Gutter | Wall | vs mt8 | Metatiles | Max MT | SSIM vs mt8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mt4 | 4 | 1 | 42.5 s | 1.28× slower | 20 | 7.6 s | **FAIL** (mean 0.989, min 0.843) |
| mt8 | 8 | 1 | **33.1 s** | ref | 6 | 16.1 s | reference |
| mt16 | 16 | 1 | 30.0 s | 0.91× (~9 % faster) | 2 | 20.1 s | **FAIL** (mean 0.989, min 0.848) |
| gutter0 | 8 | 0 | 24.0 s | 0.73× | 6 | 11.0 s | **FAIL** (mean 0.984, min 0.833) |

## Verification

- All cases exit 0, same tile count (196).
- SSIM gate: mean looks fine (~0.98+) but **min tile SSIM falls below 0.95** for every non-default knob — label/symbol placement differs across metatile seams (and gutter 0 clips).

## Decision

**Keep defaults: `--metatile 8 --gutter 1`.**

- mt4: worse wall (more jobs + gutter overlap tax), fails equivalence.
- mt16: small wall win (~3 s on this AOI), fails equivalence — not worth visual drift.
- gutter 0: largest wall win (~27 %), fails equivalence (expected label/clip artifacts).

## Notes

- Large-bbox DB still in Postgres made earlier starter z15–18 metatile runs crawl; re-prep starter before knob A/B.
- z18 remains expensive per metatile (max ~16–20 s at mt8/16); further wins need layer/zoom budget, not metatile size alone.

## Reproduce

```bash
BBOX=13.4132,52.4715,13.4312,52.4821 ./docker/run-berlin.sh   # if DB is a larger extract
ZMIN=18 ZMAX=18 ./audit/render-explore/run-metatile-explore.sh
```
