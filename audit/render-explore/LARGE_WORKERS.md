# Large-bbox worker scaling (2026-08-01)

**BBox:** `13.3958,52.4243,13.4874,52.4849`  
**Zoom:** 16 only (342 tiles, 12 metatiles) — z15–17 alone was ~1 h+ per case; z18 omitted (multi-hour).  
**Raw:** `audit/render-explore/20260801T135036Z_large-workers/` (gitignored)

| Case | Workers | Wall | vs 1× | Avg MT | Max MT | CPU-sum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| workers1 | 1 | **274.2 s** | 1.00× | 22.6 s | 53.5 s | 271 s |
| workers2 | 2 | **176.4 s** | **0.64×** (~1.6× faster) | 27.4 s | 61.6 s | 329 s |
| workers4 | 4 | **166.7 s** | 0.61× | 40.1 s | 95.8 s | 481 s |

## Verification

- All three cases exit 0, same tile count (342).
- Wall improves from 1→2 workers; 4 workers only ~6 % better than 2 on this job.
- CPU-sum rises with workers (DB/paint contention); wall ≪ CPU-sum at 4× shows overlap but diminishing returns.

## Takeaways

1. **`--workers 2` is the sweet spot** on this host for large-bbox density (matches starter-bbox explore).
2. **4 workers not worth it** here: little wall gain, much higher max metatile and CPU-sum.
3. Only **12 metatiles** at z16 for this bbox — higher zooms have more metatiles and may scale better, but z18 remains cost-dominated by paint, not worker count alone.

## Reproduce

```bash
# defaults: ZMIN=ZMAX=16, workers 1/2/4
./audit/render-explore/run-large-workers.sh

# fuller (slow):
ZMIN=15 ZMAX=17 CASES="workers1 workers2 workers4" ./audit/render-explore/run-large-workers.sh
```
