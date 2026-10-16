# Design presets: performance notes

Scope: the design-research presets `--layers la` and `--layers ink` (and the
`SRK_INK_OBLIQUE=freestanding` variant). Goal: faster tiles with unchanged
pixels; one deliberate exception, the railway seam fix, is listed separately.

## How to measure

```bash
cd rust/srk-render && cargo build --release
DB_PORT=5433 PGPASSWORD=postgres ./target/release/srk-render \
  --bbox 13.4132,52.4715,13.4312,52.4821 --zmin 17 --zmax 18 --layers la \
  --metatile 4 --gutter 1 --workers 4 --format webp --out /tmp/perf --quiet --profile
# -> /tmp/perf/timing.json (ms_per_tile by zoom)
```

`SRK_KIT_PROFILE=1` also logs every style-kit SQL query (ms, rows) and its
label to stderr. It is off by default and costs nothing when unset.

Hot-spot search: `sample <pid> 20` on a single-zoom run (macOS), ranked by
top-of-stack sample count.

**Machine caveat.** The machine was shared with a photogrammetry job and
several Docker stacks; the 1-minute load average was between 30 and 190 during
the session. Absolute ms/tile moved by ±20 % between runs of the *same*
binary. Only A/B pairs run back to back are comparable, so the ratios are the
result.

## Where the time goes (baseline, `la`, z18, 4 workers)

Sampled top-of-stack on the baseline binary:

| rank | function                                      | notes                                  |
|------|-----------------------------------------------|----------------------------------------|
| 1    | `style_kit::box_line` (blur, column walk)     | largest CPU consumer in the renderer   |
| 2    | `tiny_skia` path filling (`fill_path_impl`)   | largest after the blur was fixed       |
| 3    | `style_kit::apply_grain` / `fbm`              | a few % of samples                     |
| –    | `point_in_polygon` (trees vs woods)           | not in the top 30 at this bbox        |

Most wall time is not renderer CPU: over z16–19 on the full bbox the renderer
used about 110 s of user CPU in a 465 s wall run; the rest is waiting on
PostGIS and idle workers. Individual SQL queries took 1–80 ms each. In
EXPLAIN ANALYZE the `draw_buildings` anti-join (`NOT EXISTS … ST_DWithin`)
takes ~2 ms for 15 landuse candidates, so no SQL change was made. GiST indexes
exist on `building`, `landuse`, `tree` and `label_highway`, and a btree on
`label_highway.zoom`.

## What changed

Commits on `claude/design-perf-363389`:

### 1. `1b91f45` Blur: only the opaque bounding box, row-wise vertical pass

`style_kit::blur_layer` ran three box-blur passes over the full pixmap for
every `new_layer` (shadows, water edge, lawn rim, tree shadows). Now:

- it finds the bounding box of non-transparent pixels and grows it by
  `3·radius + 2` (the reach of three box passes); everything outside stays
  zero, so the result is unchanged;
- the vertical pass copies and sweeps whole rows at once, so it reads and
  writes contiguous memory instead of walking columns with a stride.

Also adds `SRK_KIT_PROFILE=1` (see above).

### 2. `e5e73ca` Blur: division by the window size → multiply-shift

Each output channel was `sum / (2r+1)` with a runtime divisor. For windows
below 4096 it is now `(sum · m) >> 32` with `m = floor(2³² / win) + 1`. This
is exact for every sum that can occur (`sum ≤ 255·win < 2³²/win`), so the
output bytes are identical. Larger windows keep the plain division.

### 3. `47207db` Railway ties from whole lines (seam fix; pixels change)

`railway_lines()` used the clipped `ctx.lines`, so the sleepers and ties
(`along()`-based) restarted at the render-buffer edge and differed between
metatile layouts. It now uses `ctx.lines_full`, so their phase is anchored
to the world. This is the one change that alters pixels on purpose: only
tiles that contain railways change.

## Results

### Pixel identity (commits 1 and 2)

`cmp` over 143 tiles (z16–19, metatile 4) of a small bbox, baseline vs. HEAD
for commits 1 and 2: **max channel difference 0** for both `la` and `ink`.

### Railway seam fix (commit 3)

Tiles near railways, bbox 13.4380,52.4670 – 13.4430,52.4710, z18, metatile 1 vs. 4
(20 tiles, share of pixels with a difference > 8/255):

| preset | baseline seam mean | after  | baseline worst | after  |
|--------|--------------------|--------|----------------|--------|
| la     | 0.590 %            | 0.063 %| 5.83 %         | 1.22 % |
| ink    | 0.473 %            | 0.045 %| 3.97 %         | 0.64 % |

Baseline-vs-new pixel differences on the same tiles (metatile 4): up to 6.7 %
of pixels in the worst `la` tile, because the railway tiles are redrawn. Tiles
without railways are unchanged.

### Seam check (`tools/seam_check.sh`, the standard bbox, z19)

Unchanged by commit 3 (the standard bbox has no railway):

| preset | mean pixels differing | worst tile |
|--------|----------------------|------------|
| la     | 0.062 %              | 0.84 %     |
| ink    | 0.087 %              | 2.27 %     |

Both means are below the 0.1 % limit. The worst `ink` tile (2.27 %) predates
these changes; it is not investigated here.

### Timing (z17–18, metatile 4, 4 workers, one round, back-to-back)

Baseline vs. commits 1 and 2 (`new` = build at `e5e73ca`; the railway commit
was built after this run):

| preset                       | baseline ms/tile | new ms/tile | ratio |
|------------------------------|------------------|-------------|-------|
| `la`                         | 554.3            | 395.8       | 0.71  |
| `ink`                        | 615.0            | 526.3       | 0.86  |
| `ink` `SRK_INK_OBLIQUE=freestanding` | 519.6    | 441.6       | 0.85  |

Single-zoom z18 `la` (earlier, same machine state caveat): baseline 713 and
830 ms/tile in two runs, 498 ms/tile after commit 2 (ratio ≈ 0.6–0.7).

Only one round was measured, because the second round did not fit before the
deadline. The ratios come from one back-to-back pair per configuration on a
loaded machine; treat them as indicative.

## What did not help / was not done

- **Hatch and grain noise (`apply_grain`, `fbm`)** is a few percent of CPU.
  Caching the noise lattice or evaluating it at lower resolution would change
  the pixels, so it was left for a deliberate look change.
- **`hatch_path` clipping** (suggested by the tests session): not changed. The
  hatch lines are unbounded lines with endpoints outside the buffer; the
  mask already hides everything outside the buffer, so the visible result
  should only depend on endpoint rounding. This was reasoned about, not
  measured.
- **`Ctx::ref_scale` at z ≤ 11** (also from the tests session): not touched;
  outside the z16–20 range this work targets.
- **`point_in_polygon` for trees** against every wood polygon was not in the
  sampled top stacks at this bbox. A bbox prefilter per wood would help dense
  forest tiles; not measured, so not done.
- **SQL.** No index was missing and no query was slow enough to justify a
  change. The database was not modified.
- **tiny-skia path filling** is now the largest self-time. Reducing it means
  fewer or simpler paths, which changes drawing, so it was left alone.
