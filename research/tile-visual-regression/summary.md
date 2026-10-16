# Tile visual regression testing

Methodology for proving that a **candidate tile renderer** (planned Rust) matches the **reference renderer** (PyQGIS + QGIS project) on the same PostGIS input. Primary grounding: image-comparison literature and tools, plus render-test harnesses from QGIS, MapLibre, Mapnik, resvg, Skia Gold, and web visual-regression tooling.

The problem is harder than "same bytes": anti-aliased vector cartography, sub-pixel geometry, label placement, metatile gutters, and JPEG production tiles all make naive pixel equality misleading. The chapters below collect **metric choices → prior art → sampling → seams → triage → CI → concrete harness design** for this repo.

---

## 1. Metrics

### 1.1 Naive per-pixel RGB distance

**What it measures:** For each pixel, Euclidean or max-channel distance in 8-bit sRGB (`|R1-R2|`, etc.), optionally summed or averaged over the image.

**Implementations:** Trivial in NumPy (`audit/tile-compare/compare-tiles.py` uses `max(|dR|,|dG|,|dB|) > threshold`); Rust via `image` crate raw buffers; ImageMagick `compare -metric AE` (absolute error count) or `RMSE`.

**Pitfalls for map tiles:**

- A **1 px shift** of a 1 px anti-aliased line changes tens of pixels from near-white to near-black — catastrophic score despite visually identical cartography.
- **JPEG** tiles (this project's production default in `render/xyz_tiles.py`) introduce blocking and colour quantisation; two renders of the same PNG can differ in "identical" regions after encode/decode.
- Comparing in **gamma-encoded sRGB** overweightes dark differences; comparing in **linear RGB** is physically correct for blur/scale but does not match monitor perception for threshold tuning.

**When to use:** Fast sanity check on **already-aligned** tiles, with a **channel tolerance** (QGIS uses per-channel `colorTolerance`; resvg allows 1-4 LSB). Pair with a diff image for debugging, not as the sole gate during renderer migration.

### 1.2 pixelmatch (JS) and Rust ports

**What it measures:** Count of "different" pixels after (a) optional anti-aliased-pixel detection, (b) perceptual colour distance in **OKLab / HyAB** ([pixelmatch README](https://github.com/mapbox/pixelmatch/blob/master/README.md)). Returns mismatch count; ratio = mismatches / (width * height).

**Implementations:**

| Tool | Licence | Notes |
| --- | --- | --- |
| [pixelmatch](https://github.com/mapbox/pixelmatch) (JS) | ISC | Used by MapLibre render tests, Playwright `toHaveScreenshot`; CLI for PNG |
| [pixelmatch](https://docs.rs/crate/pixelmatch) / [pixelmatch-rs](https://github.com/dfrankland/pixelmatch-rs) (Rust) | MIT | Port of older YIQ-based pixelmatch |
| [odiff](https://github.com/dmtrKovalenko/odiff) | MIT | SIMD-native; Node + CLI; benchmarks faster than pixelmatch |
| [blazediff](https://crates.io/crates/blazediff) | Apache-2.0 | Block-skipping + SIMD; YIQ + AA detection |
| [dify](https://github.com/jihchi/dify) | MIT | Pixel-by-pixel Rust CLI |

**MapLibre defaults** ([`run_render_tests.ts`](https://github.com/maplibre/maplibre-gl-js/blob/e00439bd/test/integration/render/run_render_tests.ts)): `threshold: 0.1285`, pass if `pixelmatch(...) / pixels <= allowed` where default `allowed = 0.00025` (0.025% of pixels). Per-test overrides live in `style.json` -> `metadata.test.allowed` ([Mapbox integration README](https://github.com/mapbox/mapbox-gl-js/blob/main/test/integration/README.md) warns values >= 0.01 are usually too high).

**When to use:** **Primary CI gate** for 256x256 PNG tiles — same role as `vector/scripts/screenshots.ts` (threshold `0.1`, score = mismatched / area). Good AA handling; still **shift-sensitive** unless combined with blur or windowed density ([pixelmatch `windowSize`](https://github.com/mapbox/pixelmatch/blob/master/README.md)).

### 1.3 ImageMagick `compare`

**What it measures:** Many metrics via `-metric`: **AE** (absolute count of different pixels), **RMSE**, **PAE** (peak absolute error), **PSNR**, **NCC** (normalised cross-correlation; also supports `-subimage-search` for offset finding). **`-fuzz distance`** treats colours within distance as equal ([ImageMagick compare docs](https://imagemagick.org/script/compare.php)).

**Licence:** ImageMagick licence.

**When to use:** Shell pipelines and quick probes; `-subimage-search` useful to detect **accidental translation**. Less maintained as a single "perceptual" score than dedicated metrics below. Prefer PNG input; JPEG `-fuzz` can hide real regressions.

### 1.4 perceptualdiff

**What it measures:** Yee's **perceptual metric** (human visual system model) from the 2004 JGT paper; outputs diff image and pass/fail ([myint/perceptualdiff](https://github.com/myint/perceptualdiff/), [pdiff.sourceforge.net](https://pdiff.sourceforge.net/)).

**Licence:** GPL (legacy tree) / check fork.

**When to use:** Offline investigation of "are these actually different to a human?" Slower, C++ dependency chain. No first-class Rust crate; not ideal for per-commit loops.

### 1.5 SSIM / MS-SSIM / DSSIM

**What it measures:**

- **SSIM** — local structural similarity (luminance, contrast, structure) per window; 1 = identical ([Wang et al.](https://ece.uwaterloo.ca/~z70wang/research/ssim/)).
- **MS-SSIM** — SSIM at multiple scales.
- **DSSIM** (Kornel) — `1/SSIM - 1`; 0 = identical, unbounded above; multi-scale in **linear-light RGB**, **L\*a\*b\*** colour space ([dssim README](https://github.com/kornelski/dssim/blob/main/README.md)). Scale changed between DSSIM versions — always record version.

**Implementations:** CLI/library [kornelski/dssim](https://github.com/kornelski/dssim) (Rust, AGPL/commercial); [image-compare](https://docs.rs/crate/image-compare) crate (Rust); `iqa-rs` wrapper ([visualcommons/iqa-rs](https://github.com/visualcommons/iqa-rs)); simplified whole-image SSIM in `audit/tile-compare/compare-tiles.py`.

**When to use:** **Shift-tolerant summary statistic** for migration dashboards. This repo already gates QGIS A/B renders at mean SSIM >= 0.98, min tile SSIM >= 0.95 (`audit/tile-compare/README.md`). DSSIM is stricter and more perceptually grounded than the simplified SSIM in `compare-tiles.py` — prefer DSSIM for Rust harness v2.

### 1.6 Perceptual metrics: Butteraugli, SSIMULACRA2, FLIP, VMAF

| Metric | Scale | Rust / CLI | Best for |
| --- | --- | --- | --- |
| [Butteraugli](https://docs.rs/butteraugli) | 0 = identical; <1 ~ imperceptible | `butteraugli` crate (libjxl port) | Compression / tone differences |
| [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2) | 0-100; 100 = identical | `ssimulacra2`, `fast-ssim2` crates | Modern perceptual QA; libjxl tool |
| [FLIP](https://github.com/NVlabs/flip) | 0-1 per-pixel map; pooled mean | `pip install flip-evaluator`; C++/CUDA | **Rendered** image comparison (HPG 2020) |
| [VMAF](https://github.com/Netflix/vmaf) | 0-100 (video) | C/CLI | Video streams; overkill for static tiles |

**FLIP** is explicitly designed for **rendered-image ground-truth comparison** ([NVIDIA FLIP paper](https://doi.org/10.1145/3406183)): models **alternating** between two images (flip-book review), not side-by-side memory. **No maintained Rust crate** as of 2026-08; use Python CLI or C++ header for nightly deep-dives, not per-tile CI.

**When to use:** Record **one perceptual scalar** (SSIMULACRA2 or DSSIM) on worst tiles for human triage; do not block CI on FLIP until runtime is acceptable (~1 s/tile unverified for 256^2).

### 1.7 Structure-aware / shift-tolerant approaches

| Technique | Mechanism | Source |
| --- | --- | --- |
| Blur-then-compare | Gaussian blur both images, then pixelmatch/SSIM | Common practice; reduces shift penalty |
| `pixelmatch` `windowSize` | Max diff count in any NxN window | [pixelmatch README](https://github.com/mapbox/pixelmatch/blob/master/README.md) |
| ImageMagick `-subimage-search` | Find best offset, then compare | [ImageMagick compare](https://imagemagick.org/script/compare.php) |
| Resemble.js `ignoreAntialiasing` | Heuristic AA detection | [Resemble.js README](https://github.com/Huddle/Resemble.js/blob/master/README.md) |
| reg-suit `enableAntialias` | Same family as Resemble | [reg-suit README](https://github.com/reg-viz/reg-suit/blob/master/README.md) |
| QGIS `_mask.png` | Per-pixel tolerance in red channel | [QgsRenderChecker](https://api.qgis.org/api/classQgsRenderChecker.html) |
| Morphological tolerance | Dilate diff mask; ignore thin rims | Implementation-specific |

**When to use:** Any time geometry may differ by <1 px between engines. For **strict** equivalence, do not blur — use masks to ignore known unstable regions (labels, transparency).

### 1.8 Colour space and JPEG

- **sRGB vs linear vs Lab:** DSSIM and SSIMULACRA2 compare in perceptual / linear-light spaces ([dssim](https://github.com/kornelski/dssim/blob/main/README.md), [fast-ssim2](https://docs.rs/fast-ssim2)). **Delta E / CIEDE2000** ([`iqa-rs`](https://github.com/visualcommons/iqa-rs)) measures colour appearance; useful for palette regressions, not full scene structure.
- **JPEG:** Lossy; never use production `.jpg` tiles as the **sole** comparison artefact. **Recommendation:** comparison runs use **`--format png`** in `render/xyz_tiles.py` (already supported); store PNG pairs in gitignored output dirs. Optionally run a second pass with JPEG at quality 85 to bound production-format drift.
- **Background:** `#ededed` default; pixelmatch had a **white vs transparent** blind spot ([maplibre-gl-js#4862](https://github.com/maplibre/maplibre-gl-js/issues/4862), fixed in pixelmatch 7.x). Use opaque backgrounds in fixtures.

### 1.9 Recommended metric set (this project)

Record **three scalars per tile** plus a diff PNG. The threshold columns below are **starting points carried over from other projects, not measured on this map** — treat them as unverified until calibrated against hand-reviewed tile pairs.

| # | Metric | Role | Suggested initial thresholds (256x256 PNG, z15-z20 street map) |
| --- | --- | --- | --- |
| 1 | **pixelmatch ratio** (`threshold` 0.1, `includeAA: false`) | Strict gate; catches wrong colours, missing layers | `pass <= 0.02`, `needs-review <= 0.08`, else `fail` |
| 2 | **DSSIM** (v3.x CLI) | Migration progress tracker; tolerates minor AA | `pass <= 0.01`, `needs-review <= 0.05` |
| 3 | **SSIMULACRA2** (`fast-ssim2`) | Perceptual sanity on worst tiles | `pass >= 90`, `needs-review >= 75` |

**Verdict logic:** `fail` if any metric in fail band; `needs-review` if not fail but any metric in review band or diff area > 5% of tile; else `pass`. During early migration (most tiles red), CI should **not** fail on absolute score — only on **regression vs last approved baseline** (see section 5).

Tune thresholds on ~50 hand-reviewed tile pairs before enforcing hard CI gates.

---

## 2. Prior art worth copying

### 2.1 QGIS `QgsRenderChecker` / `QgsMultiRenderChecker`

**Layout:** `tests/testdata/control_images/{testName}/` with `{testName}.png`; optional `{testName}_mask.png` where **red channel = per-pixel colour tolerance** ([QgsRenderChecker source](https://api.qgis.org/api/master/qgsrenderchecker_8cpp_source.html)).

**Thresholds:** `mismatchCount` = max differing pixels; `setColorTolerance(unsigned)` per channel; `setSizeTolerance(x, y)` for dimension slack. `QgsMultiRenderChecker` supports **multiple platform subfolders** and picks best match ([QgsMultiRenderChecker API](https://api.qgis.org/api/classQgsMultiRenderChecker.html)).

**Reports:** `report()` / `markdownReport()` HTML; `shouldGenerateReport()` for CI ([QgsRenderChecker API](https://api.qgis.org/api/classQgsRenderChecker.html)).

**Copy:** Mask images for label-heavy tiles; per-test mismatch budget; HTML side-by-side in gallery.

### 2.2 Mapnik visual tests

**Layout:** Separate repos — styles in `mapnik/test-data-visual/styles/`, references in `images/*-reference.png` ([mapnik/test-data-visual](https://github.com/mapnik/test-data-visual)). Runner: `./test/visual/run` with `--overwrite`, `--jobs`, renderer flags ([Mapnik contributing](https://github.com/mapnik/mapnik/blob/master/docs/contributing.md)).

**Copy:** Naming convention encodes size, scale, renderer (`512-512-2.0-cairo-reference.png`); filter by test name; parallel jobs.

### 2.3 MapLibre GL JS render tests

**Layout:** `test/integration/render/tests/{property}/{case}/style.json` + `expected.png` (+ optional `expected-*.png` for platforms). Assets under `test/integration/assets/` with `local://` URLs ([MapLibre integration README](https://github.com/maplibre/maplibre-gl-js/blob/main/test/integration/README.md)).

**Thresholds:** `metadata.test.allowed` (fraction of differing pixels), `metadata.test.threshold` (colour sensitivity). Default allowed `0.00025` ([`run_render_tests.ts`](https://github.com/maplibre/maplibre-gl-js/blob/e00439bd/test/integration/render/run_render_tests.ts)).

**Failures:** `results.html` gallery; CI uploads artifacts; `UPDATE=true` to refresh baselines.

**Copy:** Per-fixture metadata JSON; HTML report; multiple accepted baselines; explicit warning against large `allowed`.

### 2.4 maplibre-native render-test

**Layout:** Shares GL JS fixtures; adds `ignores.json` mapping test id -> reason ([`manifest_parser.cpp`](https://github.com/maplibre/maplibre-native/blob/04c4507f/render-test/manifest_parser.cpp)). Default `allowed = 0.00015` ([`metadata.hpp`](https://github.com/maplibre/maplibre-native/blob/04c4507f/render-test/metadata.hpp)). Uses **mapbox pixelmatch** C++ ([`runner.cpp`](https://github.com/maplibre/maplibre-native/blob/04c4507f/render-test/runner.cpp)).

**Copy:** `ignores.json` for known diffs during migration; "ignored failed" vs "ignored passed" triage states.

### 2.5 Tilemaker / planetiler / tippecanoe

**Finding:** No golden **raster tile** regression suites in these projects. Planetiler has **`compare`** for vector tile archives (feature/layer IDs, not pixels) ([planetiler PR #780](https://github.com/onthegomap/planetiler/pull/780)); unit/integration tests for **vector contents** ([planetiler-examples](https://github.com/onthegomap/planetiler/tree/main/planetiler-examples)). Tippecanoe: geometry/stat tests, not map styling.

**Copy:** Separate **data equivalence** (SQL digests, vector compare) from **render equivalence** (this harness).

### 2.6 resvg test suite

**Scale:** ~1600 SVG-to-PNG regression tests ([resvg README](https://github.com/linebender/resvg)); references in [resvg-test-suite](https://github.com/linebender/resvg-test-suite). Tolerance: **`is_pix_diff` with 1 LSB per channel** (4 LSB when dependency noise warrants) ([resvg#942](https://github.com/linebender/resvg/issues/942)).

**Copy:** Committed PNG references; explicit LSB tolerance; version-pin dependencies for reproducibility.

### 2.7 Chromium / Skia GM tests and Skia Gold

**Concepts** ([Skia Gold docs](https://docs.skia.org/docs/dev/testing/skiagold/)):

- **Digest** = hash of pixel content; untriaged digest = new output needing human review.
- **Positive triage** = acceptable diff; **negative** = bug.
- **Ignores** with expiry for bulk rebaseline during CLs.
- Baselines **outside git** but tied to commits (Skia Gold web UI).

**Copy for this repo:** Git-checked **per-tile budget JSON** instead of SaaS Gold; same triage vocabulary (pass / needs-review / ignored); blame sorted gallery.

### 2.8 Web visual-regression tooling (reuse vs rebuild)

| Tool | Reuse for |
| --- | --- |
| [Playwright `toHaveScreenshot`](https://playwright.dev/docs/test-snapshots) | Same pixelmatch engine; `maxDiffPixelRatio`, `threshold` — good for **browser** compare UI, not bulk tiles |
| [reg-suit](https://github.com/reg-viz/reg-suit) | S3/GCS snapshot workflow; `thresholdRate`, `enableAntialias` — heavy for tile CI |
| [BackstopJS](https://github.com/garris/BackstopJS) | Scenario-based web captures — reference for HTML report UX |
| Percy / Chromatic / Argos | SaaS triage — note only; not recommended for OSS geo pipeline |

**Copy:** HTML gallery pattern from `vector/scripts/screenshots.ts` (dark theme, sorted cards, `scores.json`); do **not** drive 10k tile compares through Playwright.

---

## 3. Tile sampling and coverage

### 3.1 Stratified sampling for OSM street-space maps

Build a tile manifest `audit/tile-regression/manifest.json` with strata:

| Stratum | Intent | Selection hint |
| --- | --- | --- |
| **Density** | Urban core vs sparse edge | `COUNT(*)` per tile from buildings/roads grouped by `ST_TileEnvelope` |
| **Feature class** | Every styled layer seen at least once | `EXISTS` subquery per `layer_name` / SQL script output table |
| **Hard geometry** | Bridges, tunnels, `layer!=0`, complex intersections | `bridge=yes`, `tunnel=yes`, `ST_NPoints(geom) > N` |
| **Boundaries** | Water/landuse, admin, forest/park edges | `ST_Touches` between class pairs |
| **Labels** | Dense `label_*` tables | High label point count per tile |
| **Tile edges** | Seam-sensitive features crossing borders | Features with `ST_Crosses` tile envelope boundary |
| **Zoom sweep** | z15-z20 | At least N tiles per zoom per stratum |

Hand-pick **anchor tiles** (like `vector/locations.ts`: intersection, dense trees, parking, water edge) and supplement with SQL-driven picks.

### 3.2 PostGIS tile queries

```sql
-- Tiles at z17 intersecting buildings (Web Mercator envelope)
SELECT DISTINCT 17 AS z,
       FLOOR((ST_X(ST_Transform(geom, 3857)) + 20037508.34) / (40075016.68 / power(2, 17)))::int AS x,
       FLOOR((20037508.34 - ST_Y(ST_Transform(geom, 3857))) / (40075016.68 / power(2, 17)))::int AS y
FROM building
WHERE geom && ST_Transform(ST_TileEnvelope(17, x, y), 4326);
```

Use `ST_TileEnvelope(z, x, y)` for exact bounds; optional `margin` for gutter-aware feature pull ([PostGIS `ST_TileEnvelope`](https://postgis.net/docs/ST_TileEnvelope.html)).

**Coverage tracker:** Maintain `coverage.json` — map each QGIS layer id / symbol rule id to list of tile ids that exercise it. CI fails if a new style rule has zero tiles (warn during migration).

### 3.3 Corpus size: per-commit vs nightly

| Suite | Tiles | When |
| --- | ---: | --- |
| **smoke** | ~30 | Every PR; anchors + 1 tile per major layer |
| **standard** | ~300 | Nightly; stratified sample across Neukoelln starter bbox |
| **full** | ~3000+ | Weekly / pre-release; all strata x all zooms |

Same manifest schema; `suite: "smoke" | "standard" | "full"` field.

### 3.4 Reproducibility (input pinning)

Diffs must be **renderer-only**, not data drift:

| Layer | Approach |
| --- | --- |
| OSM extract | Committed small PBF (e.g. Neukoelln) + SHA256 in `manifest.json` |
| PostGIS | Fixed Docker image / `docker/` compose; pin osm2pgsql + SQL git SHA |
| SQL outputs | Reuse `audit/sql-compare/` freeze workflow before render compare |
| Fonts | Pin `render/fonts/`; QGIS and Rust must load same files |
| QGIS project | Pin `.qgz` version + `render/xyz_tiles.py` git SHA |
| Randomness | Disable non-deterministic label seeds if any; fixed DPI 96 |

Document checksums in `audit/tile-regression/fixture-lock.json` (similar spirit to `audit/sql-compare/reference/`).

---

## 4. Seam and boundary verification

### 4.1 The crop-vs-tile trick

**Problem:** Per-tile rendering with metatile gutter (`--metatile 8 --gutter 1` in `render/xyz_tiles.py`) can still produce **seams** if the candidate engine clips differently.

**Test:**

1. Render a **large single image** for a bbox covering a 3x3 or 5x5 tile block at fixed zoom (one map settings extent, no tile cutting).
2. Render the **same bbox** as individual XYZ tiles.
3. **Stitch** tiles (or compare each tile to the corresponding crop of the large image).

Mismatch at tile interior edges (not just 1 px AA rim) implies a seam bug.

### 4.2 Gutter / metatile implications

Reference renderer expands each metatile by `gutter` tiles, renders, writes **core only** ([`render/xyz_tiles.py`](../../render/xyz_tiles.py)). Candidate must replicate:

- Same effective scale (`@mercator_scale`, DPI 96).
- Same gutter discard semantics.
- Seam test is **independent** of gutter — it catches errors in tile-boundary clipping even when gutter is correct.

### 4.3 Optional offset search

If compare fails with striped patterns, run ImageMagick `compare -metric NCC -subimage-search` on tile vs crop to estimate integer pixel offset ([ImageMagick compare](https://imagemagick.org/script/compare.php)). Persistent non-zero offset implies transform bug.

---

## 5. Baselines, triage and acceptable-diff budgets

### 5.1 Per-tile state machine

| State | Meaning |
| --- | --- |
| `pass` | All metrics within pass bands |
| `needs-review` | Visually maybe OK; human must approve budget |
| `fail` | Regression vs approved baseline or over hard threshold |
| `ignored` | Known difference; reason in `ignores.json` |

MapLibre pattern: `ignores.json` `{"test/id": "reason"}` — skip or expect failure ([manifest_parser.cpp](https://github.com/maplibre/maplibre-native/blob/04c4507f/render-test/manifest_parser.cpp)).

QGIS pattern: `_mask.png` + `mismatchCount` ([QgsRenderChecker](https://api.qgis.org/api/classQgsRenderChecker.html)).

### 5.2 Checked-in budgets

`audit/tile-regression/budgets/{z}/{x}/{y}.json`:

```json
{
  "pixelmatch_max": 0.12,
  "dssim_max": 0.08,
  "ssimulacra2_min": 72,
  "mask": "masks/17-12345-67890.png",
  "reviewed": "2026-08-01",
  "reason": "label placement differs 1px; tracked in #NNN"
}
```

CI: compute metrics; **fail only if metrics exceed budget** (regression) or **no budget and metrics in fail band** (new tile). Approving `needs-review` = commit budget file (human-reviewed).

### 5.3 Incremental migration tracking

Aggregate `summary-by-layer.json`:

```json
{ "building": { "tiles": 42, "mean_dssim": 0.34, "pass": 3, "review": 12, "fail": 27 } }
```

Generated by rendering **layer isolates** (section 6.3). Plot over time in CI artifacts — goal is rising pass count per layer, not binary all-green until late migration.

---

## 6. Reports and CI

### 6.1 Artefacts

Per run directory `audit/tile-regression/runs/{timestamp}-{git-sha}/`:

| File | Content |
| --- | --- |
| `summary.json` | Machine-readable: counts, worst tiles, layer aggregates |
| `tiles.jsonl` | One record per tile: metrics, verdict, paths |
| `index.html` | Gallery: ref / cand / diff; sorted by DSSIM desc |
| `tiles/{z}/{x}/{y}/` | `ref.png`, `cand.png`, `diff.png` |

Match tone/layout of `vector/compare-output/index.html` (dark cards, 3-column grid, sorted by score).

### 6.2 Human review aids

- **Flip-book:** animated GIF or HTML A/B toggle (FLIP's intended review mode — [FLIP paper](https://doi.org/10.1145/3406183)).
- **Layer isolate:** same tile with only one QGIS map layer enabled (both engines).
- **Symbol isolate:** single symbol layer / rule where QGIS project structure allows.

### 6.3 CI integration

| Job | Command | Gate |
| --- | --- | --- |
| PR smoke | `bun run tile-regression --suite smoke` | No **regression** vs `budgets/`; warn on new fails |
| Nightly | `--suite standard` | Upload `index.html` artifact; optional Slack on trend |
| Manual | `--suite full --write-budgets` | Human triage session |

Pattern from `audit/sql-compare/`: exit `0` match / `1` drift. Gitignore `audit/tile-regression/runs/**`; commit only `budgets/`, `manifest.json`, `ignores.json`.

---

## 7. Recommended harness design for this repo

Concrete design for implementers. Extends existing `audit/tile-compare/` (QGIS vs QGIS) to **reference vs candidate** migration.

### 7.1 Directory layout

```
audit/tile-regression/
  README.md
  manifest.json           # tile list + suites + fixture checksums
  fixture-lock.json       # PBF/SQL/QGIS project hashes
  ignores.json            # MapLibre-style known diffs
  budgets/                # committed per-tile allowances (sparse)
    {z}/{x}/{y}.json
  masks/                  # optional PNG masks (QGIS-style)
  runs/                   # gitignored outputs
    {timestamp}-{sha}/
      summary.json
      tiles.jsonl
      index.html
      tiles/{z}/{x}/{y}/{ref,cand,diff}.png
  scripts/
    sample-tiles.ts       # PostGIS -> manifest (stratified)
    render-tile.ts        # invoke ref and/or cand for one z/x/y
    compare-tile.ts       # pixelmatch + DSSIM + SSIMULACRA2
    compare-run.ts        # batch + HTML gallery + exit code
    seam-check.ts         # large render vs tile crop
```

Keep `audit/tile-compare/` for **QGIS parity** checks (workers, metatile); `tile-regression/` is for **engine migration**.

### 7.2 Commands

```bash
# 1. Pin data (reuse sql-compare)
./audit/sql-compare/run-reference.sh

# 2. Sample tiles into manifest (or use committed smoke manifest)
bun run audit/tile-regression/scripts/sample-tiles.ts \
  --bbox 13.4132,52.4715,13.4312,52.4821 --suite smoke --out audit/tile-regression/manifest.json

# 3. Render one tile — reference (QGIS)
#    Today's CLI takes an extent, not tile indices:
#      --extent "xmin,xmax,ymin,ymax" --zmin/--zmax/--metatile/--gutter
#    A single-tile mode (--tiles z/x/y, deriving the extent from the indices)
#    has to be added to render/xyz_tiles.py first; the call below assumes it.
python3 render/xyz_tiles.py --project style/strassenraumkarte.qgz \
  --tiles 17/70445/43122 --format png --metatile 1 --gutter 1 --workers 1 \
  --out /tmp/tile-regression/ref

# 4. Render one tile — candidate (Rust CLI; does not exist yet)
# tile-renderer --tiles 17/70445/43122 --format png --out /tmp/tile-regression/cand

# 5. Compare
bun run audit/tile-regression/scripts/compare-tile.ts \
  /tmp/tile-regression/ref/17/70445/43122.png \
  /tmp/tile-regression/cand/17/70445/43122.png \
  --out /tmp/tile-regression/diff.png

# 6. Full suite
bun run audit/tile-regression/scripts/compare-run.ts \
  --manifest audit/tile-regression/manifest.json \
  --ref-cmd '...' --cand-cmd '...' \
  --out audit/tile-regression/runs/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short HEAD)
```

`compare-run.ts` should mirror `vector/scripts/screenshots.ts`: build `rows[]`, sort by `dssim` descending, emit `index.html` + `summary.json`, exit `1` on regression.

### 7.3 Per-tile record (`tiles.jsonl`)

```json
{
  "id": "17/70445/43122",
  "z": 17, "x": 70445, "y": 43122,
  "strata": ["anchor:intersection", "layer:road_marking"],
  "pixelmatch": 0.034,
  "dssim": 0.021,
  "ssimulacra2": 88.4,
  "verdict": "needs-review",
  "regression": false,
  "paths": { "ref": "tiles/17/70445/43122/ref.png", "diff": "..." }
}
```

### 7.4 Layer / rule attribution

1. **QGIS side:** duplicate project variants or layer visibility flags — render with single layer group visible (pattern from QGIS unit tests using `QgsMapSettings` layers list).
2. **Rust side:** same layer filter in candidate.
3. Compare isolate output; attribute residual diff to that layer.
4. Store `summary-by-layer.json` in run root; use for migration burndown charts.

### 7.5 Seam suite

`seam-check.ts` on manifest subset `strata: ["seam"]`:

- Call QGIS to render 5x5 tile block as one PNG (custom extent).
- Render 25 tiles; crop-center 256 px from each; compare to mosaic positions.
- Fail if any crop has `pixelmatch > 0.005` or `dssim > 0.002` vs mosaic.

### 7.6 Integration with existing harnesses

| Existing | Role in migration |
| --- | --- |
| `audit/sql-compare/` | Block render compare if data prep drifted |
| `audit/tile-compare/compare-tiles.py` | Validate QGIS reference stability (SSIM) before trusting ref tiles |
| `vector/scripts/screenshots.ts` | UX reference for HTML gallery; different domain (viewport, not XYZ) |
| `vector/locations.ts` | Seed lat/lon -> tile ids for anchor stratum |

### 7.7 Phased rollout

1. **Phase A:** Wrap `compare-tiles.py` metrics + add pixelmatch diff PNGs; PNG-only ref/cand.
2. **Phase B:** Add `budgets/` + `ignores.json` + regression-only CI.
3. **Phase C:** `sample-tiles.ts` + coverage.json per QGIS layer.
4. **Phase D:** Rust candidate wired; layer isolates; seam-check.
5. **Phase E:** Tighten default thresholds as pass rate > 90% on standard suite.

---

## Research sources

Full bibliography: [sources.md](./sources.md).
