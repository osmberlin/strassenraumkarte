# Tile visual equivalence (SSIM + pixel diff)

Compare two XYZ tile trees (e.g. workers=1 vs workers=2) with structural
similarity — not byte-identical JPEGs.

```bash
# one-time
./audit/tile-compare/setup.sh

# freeze reference (starter bbox, 1 worker)
./audit/tile-compare/freeze-reference.sh

# render candidate then compare
./render/render_tiles.sh --bbox 13.4132,52.4715,13.4312,52.4821 \
  --zmin 15 --zmax 18 --workers 2 --out /tmp/srk-cand/tiles
./audit/tile-compare/compare-tiles.py \
  audit/tile-compare/reference/starter-z15-18 \
  /tmp/srk-cand/tiles \
  --out audit/tile-compare/candidates/workers2
```

Pass when mean SSIM ≥ 0.98, min SSIM ≥ 0.95, and fraction of pixels with
|Δ| > 16 ≤ 2% (defaults overridable).
