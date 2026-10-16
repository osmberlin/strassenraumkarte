# Tile visual compare — results

## Verification A: starter bbox, workers=2 vs baseline

**Date:** 2026-08-01  
**Reference:** `audit/render-explore/20260801T131243Z/baseline/tiles`  
**Candidate:** `audit/render-explore/20260801T131243Z/workers2/tiles`  
**Zooms:** 15–18 (278 tiles)

| Metric | Value |
|--------|------:|
| Compared | 278 / 278 |
| Missing / extra | 0 / 0 |
| Mean SSIM | 1.0000 |
| Min SSIM | 0.9997 |
| Mean \|Δ\|>16 frac | 0.0001% |
| Failures | **0** |

**Verdict: PASS**

## Verification B: large bbox z16, workers=2 vs workers=1

**Date:** 2026-08-01  
**Reference / candidate:** `…/20260801T135036Z_large-workers/workers{1,2}/tiles`  
**Tiles:** 342

| Metric | Value |
|--------|------:|
| Compared | 342 / 342 |
| Mean / min SSIM | 1.0000 / 1.0000 |
| Failures | **0** |

**Verdict: PASS**

## Decision

Safe to default host renders to **`--workers 2`** (`render/render_tiles.sh` / `xyz_tiles.py`). Override with `--workers 1` or `RENDER_WORKERS=1` for A/B.

Machine reports (gitignored): `audit/tile-compare/candidates/`.

## How to re-run

```bash
./audit/tile-compare/setup.sh
./audit/tile-compare/.venv/bin/python ./audit/tile-compare/compare-tiles.py \
  REF_TILES CAND_TILES \
  --out audit/tile-compare/candidates/LABEL
```
