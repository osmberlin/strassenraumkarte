# Testing the design-research presets

The `la` and `ink` presets (and their variants) must keep three promises while the styles are
iterated:

1. **Determinism** — rendering the same tile twice gives the same pixels.
2. **Seamless metatiles** — a tile rendered alone and inside a 4×4 metatile is identical in its
   core, so tile edges never show a seam.
3. **No silent visual change** — the look of the fixed test tiles changes only when someone
   decides it should, and then the golden images are updated on purpose.

Three checks cover this, in increasing cost:

| Check | Where | Needs DB | Time |
| --- | --- | --- | --- |
| Unit tests (`style_tests.rs`) | `cargo test --release` | no | ~2 s |
| Golden regression + seam check (`regress.sh`) | `docs/design-research/tools/regress.sh` | yes (PostGIS on `localhost:5433`, read-only) | 5–12 min |
| Single-preset seam check (`seam_check.sh`) | `docs/design-research/tools/seam_check.sh la` | yes | ~30 s per preset |

## 1. Unit tests

```bash
cd rust/srk-render
cargo test --release
```

`src/style_tests.rs` (wired in by `#[cfg(test)] mod style_tests;` in `main.rs`) tests the
world-anchored helpers of `style_kit.rs` without a database. `Ctx` needs a `postgres::Client`
but the helpers never query it, so the tests connect to a small fake server on `127.0.0.1` that
only answers the startup handshake (see `fake_client()`).

What is covered:

- `hash_u64`, `rand01`, `value_noise`, `fbm`: golden values, range, continuity across lattice
  cell edges at Berlin's world coordinates.
- `world_scatter`: identical points for the single-tile and metatile extents of the same tile,
  for every seed/cell used by `la` and `ink`; density is roughly right.
- `Ctx::ref_scale`: constant over a z10 tile for z12–z19 (corners and centre, both layouts).
- `Ctx::m`, `Ctx::world`: identical across layouts.
- `hatch_path`: line positions on the world grid are identical across layouts; rasterised
  hatching in the core tile is identical for the cases the presets use.
- `apply_grain`: identical in the core tile across layouts.
- `scallop_pts`, `along`, `point_at`, `hachures`: shape, spacing, direction, edge cases.

Pinned constants (`hash_and_noise_golden_values`) change every rendered pixel if they move. If a
change to the hash or noise is intended, update the numbers in the test **and** run
`regress.sh --update` in the same commit.

### Known failures (ignored tests)

These tests describe behaviour the presets do not have yet. They are `#[ignore]`d so
`cargo test --release` stays green. Run them with `cargo test --release -- --ignored` to see
the current state. Each one should be un-ignored when its bug is fixed.

| Test | Finding | Where |
| --- | --- | --- |
| `along_on_clipped_lines_is_world_anchored` | `along()` counts from the first point of the line it is given. Lines from `Ctx::lines` are clipped by SQL to extent + 40 m, so a neighbouring metatile starts counting at a different world position and the dash/tick rhythm jumps at the seam. The test shows the same line clipped at two places gives different symbol positions. Callers that pass clipped lines: `style_la.rs` (~l. 235, 544, 666) and `style_ink.rs` (~l. 195, 309, 326). Status: the callers are fixed by passing unclipped lines from `lines_full` (LA: commit 03b7c1e on `claude/design-styles-rust`; ink: ed7888d on `claude/design-ink-features-f149c9`; not yet on this branch). `along()` itself is unchanged, so this test stays ignored. Fix idea for `along()`: anchor the phase to world arc length. | `style_kit.rs` `along`; callers in `style_la.rs` / `style_ink.rs` |
| `hatch_raster_whole_buffer_diagonal` | `hatch_path` lines are world-anchored, but when the whole render buffer is hatched at 45° the metatile buffer has longer lines, and tiny-skia rasterises them with sub-pixel differences: 4–8 % of core pixels differ at z19 for 0.5 px strokes (`style_ink.rs` playground hatch). Hatching only the core box gives 0.0 % (see `hatch_raster_identical_when_hatching_the_core_box`). Fix idea: hatch the core box plus a fixed margin instead of the whole buffer. | `style_ink.rs` ~l. 263 (playground hatch); `style_la.rs` pedestrian hatch uses the same pattern at 0°/90° and is fine there |
| `ref_scale_layouts_agree_at_low_zoom` | `ref_scale()` takes the z10 tile containing the extent's centre. At z10/z11 a 4×4 metatile spans several z10 tiles, so the two layouts pick different tiles: at z10 `1.638` vs `1.630` (≈0.5 % size difference, `10/550/336`). Only matters for z ≤ 11, which the presets are not used for. Fix idea: use the z10 tile of the *core* tile, or a fixed latitude per metatile. | `style_kit.rs` `Ctx::ref_scale` |

## 2. Golden regression: `regress.sh`

```bash
docs/design-research/tools/regress.sh              # compare against tmp/regress-baseline/
docs/design-research/tools/regress.sh --update     # render twice, check determinism, store as baseline
docs/design-research/tools/regress.sh --only ink   # cases whose name starts with "ink"
docs/design-research/tools/regress.sh --no-seam    # skip the seam check
```

Requires the release build (`cd rust/srk-render && cargo build --release`) and the PostGIS
database (defaults: `DB_HOST=localhost DB_PORT=5433 DB_USER=postgres DB_NAME=strassenraumkarte`,
`PGPASSWORD=postgres`; the same environment variables as `render_scenes.sh`).

What it does:

1. Renders a fixed tile set to PNG for six cases: `la`, `la-vivid` (`SRK_LA_PALETTE=vivid`),
   `ink`, `ink-white` (`SRK_INK_PAPER=white`), `ink-oblique` (`SRK_INK_OBLIQUE=freestanding`),
   `ink-accent-tree` (`SRK_ACCENT=tree`). Tiles: for each of the six scenes of
   `render_scenes.sh`, two z19 tiles and the z17 tile that contains them, so 18 tiles per case.
2. Compares each tile with `tmp/regress-baseline/<case>/`. A tile **changed** when more than
   `--threshold` % (default 0.1) of its pixels differ by more than 8/255 in any channel.
   Changed tiles are written to `tmp/regress-diff/<case>/` as three panels: baseline, current,
   and the differing pixels in red.
3. Runs `seam_check.sh la` and `seam_check.sh ink` (metatile 1 vs 4). Fails above 0.1 % mean
   differing pixels.

Output is one row per case, for example:

```
case                tiles  changed    worst %  worst tile             status
la                     18        0      0.000  -                      ok (4s)
```

Exit code: `0` all ok, `1` regression, seam failure or non-deterministic render, `2` missing
baseline (run `--update` first) or no build.

### When to update the baseline

Only after an intended change to the look, and after looking at the diff images. Then:

```bash
docs/design-research/tools/regress.sh --update
```

`--update` refuses to store a baseline when two identical renders differ (this would make the
golden check meaningless). The baseline itself is not committed: `tmp/` is gitignored, so each
machine creates its own baseline from a known-good commit. Record the commit in the
`tmp/regress-baseline/COMMIT` file, which `--update` writes.

## 3. Seam check: `seam_check.sh`

```bash
docs/design-research/tools/seam_check.sh la
docs/design-research/tools/seam_check.sh ink [bbox] [zoom]
```

Renders a bbox at z19 once with `--metatile 1` and once with `--metatile 4` (both `--gutter 1`)
and reports the share of pixels that differ by more than 8/255. Mean above ~0.1 % means some
state depends on the render extent instead of the world. `regress.sh` runs it for both presets.

## 4. Lint

```bash
cd rust/srk-render
cargo clippy --release --all-targets
```

`cargo clippy` currently **fails** (exit 1) because of five deny-by-default errors in the style
files. These are in the style sessions' files and were left unchanged by the test work
(checked 2026-10-16, rust 1.96):

| Lint | Where | Fix |
| --- | --- | --- |
| `clippy::approx_constant` (error) | `style_ink.rs` 747, 748, 752, 886; `style_la.rs` 449: `rand01(..) * 6.28` | use `std::f32::consts::TAU` (or `f64`) |

Warnings in the same files (not blocking):

- `style_ink.rs` 726 `draw_tree`, 774 `draw_conifer` (9 args), 808 `draw_equipment` (8 args): too many arguments.
- `style_kit.rs` 51 `Ctx::query` and 792 `railway_lines`: type complexity; a `type` alias would do.
- `style_kit.rs` 503, 650, 708: field assignment after `Default::default()`; use struct update syntax.

`style_tests.rs` is clippy-clean: `cargo clippy --release --all-targets 2>&1 | grep style_tests`
prints nothing.

## Checklist before merging a style change

1. `cargo test --release` passes (the three ignored tests may still fail; they are known).
2. `regress.sh` reports `ok` for every case, or the changed cases are intended and their diff
   images were looked at, followed by `regress.sh --update`.
3. `seam_check.sh` reports below 0.1 % for `la` and `ink`.
