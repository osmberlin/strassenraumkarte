# Research sources

Bibliography for [summary.md](./summary.md). Summaries are factual overviews of what each source covers; they are not endorsements. Items marked **unverified** were not fetched in this research pass.

## Image comparison — pixel-level

### [pixelmatch (mapbox/pixelmatch)](https://github.com/mapbox/pixelmatch)
**Mapbox**

JS pixel-level image comparison with OKLab colour distance and anti-aliased-pixel detection; CLI; used by MapLibre render tests and Playwright snapshots.

### [pixelmatch README](https://github.com/mapbox/pixelmatch/blob/master/README.md)
**Mapbox**

API (`threshold`, `includeAA`, `windowSize`), OKLab/HyAB citations, CLI usage, demo fixtures.

### [pixelmatch-rs (dfrankland/pixelmatch-rs)](https://github.com/dfrankland/pixelmatch-rs)
**dfrankland**

Rust port of pixelmatch with CLI; MIT licence; YIQ + AA slope detector papers cited.

### [pixelmatch crate (docs.rs)](https://docs.rs/crate/pixelmatch/latest)
**docs.rs**

Rust crate documentation mirroring pixelmatch-rs API.

### [odiff (dmtrKovalenko/odiff)](https://github.com/dmtrKovalenko/odiff)
**dmtrKovalenko**

SIMD-first native image diff; Node bindings; benchmarks vs pixelmatch and ImageMagick.

### [blazediff (crates.io)](https://crates.io/crates/blazediff)
**crates.io**

High-performance Rust image diff with block optimization, SIMD, YIQ perceptual diffing; claims faster than odiff on 4K fixtures.

### [dify (jihchi/dify)](https://github.com/jihchi/dify)
**jihchi**

Fast Rust pixel-by-pixel comparison CLI; PNG/JPEG/BMP; optional AA support.

### [ImageMagick compare](https://imagemagick.org/script/compare.php)
**ImageMagick**

Official `compare` command: metrics (RMSE, PSNR, NCC, AE), `-fuzz`, `-subimage-search`, similarity return codes.

### [ImageMagick command-line options — metric](https://imagemagick.org/script/command-line-options.php#metric)
**ImageMagick**

**Unverified** (fetch timed out in research pass): full list of `-metric` types and related options.

## Image comparison — structural / perceptual

### [dssim (kornelski/dssim)](https://github.com/kornelski/dssim)
**Kornel Lesiński**

Rust multi-scale SSIM (DSSIM = 1/SSIM-1); linear-light scaling; L\*a\*b\*; CLI and C/Rust/WASM library; AGPL/commercial licence.

### [SSIM (Wang et al.)](https://ece.uwaterloo.ca/~z70wang/research/ssim/)
**University of Waterloo**

Original SSIM paper and reference implementation links.

### [image-compare crate](https://docs.rs/crate/image-compare/latest)
**docs.rs**

Rust crate for image comparison (structural metrics); **unverified** — only crate index page fetched.

### [iqa-rs (visualcommons/iqa-rs)](https://github.com/visualcommons/iqa-rs)
**visualcommons**

Unified Rust API for PSNR, SSIM, MS-SSIM, DSSIM, CIEDE2000, SSIMULACRA2, Butteraugli.

### [SSIMULACRA2 (cloudinary/ssimulacra2)](https://github.com/cloudinary/ssimulacra2)
**Cloudinary / libjxl**

Perceptual metric based on MS-SSIM + asymmetric error maps; benchmark correlations vs TID datasets; also in libjxl tools.

### [fast-ssim2 (docs.rs)](https://docs.rs/fast-ssim2/latest/fast_ssim2/)
**docs.rs**

SIMD-accelerated SSIMULACRA2; score 0-100; batch reference precompute; strip mode for large images.

### [butteraugli (docs.rs)](https://docs.rs/butteraugli/latest/butteraugli/)
**docs.rs**

Rust port of Google Butteraugli from libjxl; score interpretation (<1 imperceptible).

### [FLIP (NVlabs/flip)](https://github.com/NVlabs/flip)
**NVIDIA**

LDR/HDR-FLIP metrics and tool for rendered-image error maps; Python `flip-evaluator` pip package; C++/CUDA API.

### [FLIP paper (doi:10.1145/3406183)](https://doi.org/10.1145/3406183)
**Andersson et al., HPG 2020**

Perceptual difference evaluator for alternating images; pooled histograms; comparison to SSIM/LPIPS; open-source code cited.

### [NVIDIA FLIP research page](https://research.nvidia.com/publication/flip)
**NVIDIA**

Publication abstract, downloads, HDR-FLIP follow-up pointer.

### [perceptualdiff (myint/perceptualdiff)](https://github.com/myint/perceptualdiff/)
**Steven Myint et al.**

C++ CLI implementing Yee perceptual metric; `--threshold`, `--luminance-only`, diff output.

### [pdiff / PerceptualDiff (SourceForge)](https://pdiff.sourceforge.net/)
**Hector Yee et al.**

Original perceptual diff project page; JGT 2004 paper link; build instructions.

### [Resemble.js (Huddle/Resemble.js)](https://github.com/Huddle/Resemble.js/blob/master/README.md)
**Huddle**

JS image compare with `ignoreAntialiasing`, bounding boxes, ignored regions; used as pixelmatch predecessor inspiration.

### [Netflix VMAF](https://github.com/Netflix/vmaf)
**Netflix**

Video quality metric; noted as overkill for static tiles but relevant for animated label/video tile streams.

## QGIS render testing

### [QgsRenderChecker API](https://api.qgis.org/api/classQgsRenderChecker.html)
**QGIS**

Unit-test image compare: `mismatchCount`, `setColorTolerance`, `setSizeTolerance`, `compareImages`, HTML `report()`.

### [QgsMultiRenderChecker API](https://api.qgis.org/api/classQgsMultiRenderChecker.html)
**QGIS**

Multi-platform control images; per-folder anomaly images; best-match selection.

### [QgsRenderChecker source (qgsrenderchecker.cpp)](https://api.qgis.org/api/master/qgsrenderchecker_8cpp_source.html)
**QGIS**

Mask image loading (`_mask.png`, red channel = per-pixel tolerance); mismatch reporting strings.

### [QgsRenderChecker header (release-4_0)](https://github.com/qgis/QGIS/blob/release-4_0/src/core/qgsrenderchecker.h)
**QGIS**

C++ API for control image paths, `runTest`, markdown/HTML reports.

## MapLibre / Mapbox render tests

### [MapLibre integration test README](https://github.com/maplibre/maplibre-gl-js/blob/main/test/integration/README.md)
**MapLibre**

Render test layout (`style.json`, `expected.png`), pixelmatch harness, `UPDATE` workflow, CI artifacts, `results.html`.

### [Mapbox integration test README (allowed threshold docs)](https://github.com/mapbox/mapbox-gl-js/blob/main/test/integration/README.md)
**Mapbox**

Documents `metadata.test.allowed` fraction for antialiasing tolerance; warns against large values.

### [run_render_tests.ts](https://github.com/maplibre/maplibre-gl-js/blob/e00439bd/test/integration/render/run_render_tests.ts)
**MapLibre**

Default `allowed: 0.00025`, `threshold: 0.1285`; pixelmatch ratio; multiple `expected*.png`; UPDATE overwrites baseline.

### [maplibre-native render-test metadata.hpp](https://github.com/maplibre/maplibre-native/blob/04c4507f/render-test/metadata.hpp)
**MapLibre**

`TestMetadata.allowed` default `0.00015`; test dimensions, HTML result fields.

### [maplibre-native manifest_parser.cpp (ignores.json)](https://github.com/maplibre/maplibre-native/blob/04c4507f/render-test/manifest_parser.cpp)
**MapLibre**

Parses `ignores.json` test-id -> reason; manifest `ignore_paths`.

### [maplibre-native runner.cpp (pixelmatch)](https://github.com/maplibre/maplibre-native/blob/04c4507f/render-test/runner.cpp)
**MapLibre**

C++ pixelmatch compare; `metadata.difference` vs `metadata.allowed`.

### [maplibre-gl-js#4862 (pixelmatch white/transparent)](https://github.com/maplibre/maplibre-gl-js/issues/4862)
**MapLibre**

Documents pixelmatch false negative on white vs transparent; fixed upstream in pixelmatch 7.x.

## Mapnik visual tests

### [mapnik/test-data-visual](https://github.com/mapnik/test-data-visual)
**Mapnik**

Separate visual reference image repo; styles + `*-reference.png` naming; depends on mapnik/test-data.

### [Mapnik contributing — visual tests](https://github.com/mapnik/mapnik/blob/master/docs/contributing.md)
**Mapnik**

`./test/visual/run` options: `--overwrite`, `--jobs`, renderer backends, styles/images dirs.

### [Mapnik visual tests background (issue #2575)](https://github.com/mapnik/mapnik/issues/2575)
**Mapnik**

**Unverified** — cited in test-data-visual README as motivation for split visual suite.

## resvg / Rust rasterizer tests

### [resvg (linebender/resvg)](https://github.com/linebender/resvg)
**Linebender**

~1600 SVG-to-PNG regression tests; test suite reusable independent of resvg.

### [resvg-test-suite](https://github.com/linebender/resvg-test-suite)
**Linebender**

Test file layout (`tests/`, `resources/`, `fonts/`); pre-rendered PNG references.

### [resvg#942 (zune-jpeg tolerance)](https://github.com/linebender/resvg/issues/942)
**Linebender**

`is_pix_diff` 1 LSB default; 4 LSB for dependency-induced drift; regression vs improvement ambiguity.

## Planetiler / tile pipelines (no raster golden tiles)

### [planetiler (onthegomap/planetiler)](https://github.com/onthegomap/planetiler)
**onthegomap**

Vector tile generator; unit/integration tests for profile logic, not raster cartography.

### [planetiler PR #780 — archive compare](https://github.com/onthegomap/planetiler/pull/780)
**onthegomap**

`planetiler.jar compare` diffs MBTiles/PMTiles by layer/feature IDs, not pixels.

### [planetiler-examples testing](https://github.com/onthegomap/planetiler/tree/main/planetiler-examples)
**onthegomap**

Unit and integration test patterns for custom profiles.

### [tilemaker (systemed/tilemaker)](https://github.com/systemed/tilemaker)
**systemed**

Vector tile maker from OSM PBF; no documented raster golden-tile suite.

## Skia Gold / Chromium-style triage

### [Skia Gold documentation](https://docs.skia.org/docs/dev/testing/skiagold/)
**Skia**

Web UI for visual regression triage; positive/negative; ignores; rebaseline workflow; baselines outside git.

### [Skia Infra Gold help](https://skia-infra-gold.skia.org/help)
**Skia**

Digest terminology; By Blame view; untriaged images; search/zoom diff review.

### [Skia Gardener documentation](https://docs.skia.org/docs/dev/gardening/)
**Skia**

Perf/Gold alert triage; layout test rebaselining pointers for Chromium/Skia rolls.

## Web visual regression tooling

### [Playwright visual comparisons](https://playwright.dev/docs/test-snapshots)
**Microsoft**

`toHaveScreenshot`; pixelmatch-backed; `maxDiffPixels`, `maxDiffPixelRatio`, `threshold`.

### [reg-suit (reg-viz/reg-suit)](https://github.com/reg-viz/reg-suit/blob/master/README.md)
**reg-viz**

CLI snapshot testing; `thresholdRate`, `enableAntialias`; S3/GCS publish plugins; HTML report.

### [BackstopJS (garris/BackstopJS)](https://github.com/garris/BackstopJS/blob/master/README.md)
**garris**

Scenario-based visual regression for web; reference config and report patterns.

### [x-img-diff-js](https://reg-viz.github.io/x-img-diff-js)
**reg-viz**

Structural diff engine optionally used by reg-suit reports. **Unverified** — linked from reg-suit README only.

## PostGIS / sampling

### [ST_TileEnvelope](https://postgis.net/docs/ST_TileEnvelope.html)
**PostGIS**

XYZ tile bounds in EPSG:3857; optional `margin` for buffer queries (tile gutter analog).

## This repo (conventions only — not modified)

### [audit/tile-compare/README.md](../../audit/tile-compare/README.md)
**Straßenraumkarte**

Existing SSIM + capped pixel-diff for two QGIS tile trees; threshold defaults.

### [audit/tile-compare/compare-tiles.py](../../audit/tile-compare/compare-tiles.py)
**Straßenraumkarte**

Whole-image SSIM per tile; `|delta|>16` fraction; `summary.json` + `report.md` output.

### [audit/sql-compare/README.md](../../audit/sql-compare/README.md)
**Straßenraumkarte**

Frozen PostGIS digest workflow; exit codes; re-freeze after determinism fixes.

### [vector/scripts/screenshots.ts](../../vector/scripts/screenshots.ts)
**Straßenraumkarte**

Playwright + pixelmatch HTML gallery pattern; `compare-output/index.html` + `scores.json`.

### [vector/locations.ts](../../vector/locations.ts)
**Straßenraumkarte**

Named comparison viewpoints (density-driven anchors) for raster/vector UI compare.

### [render/xyz_tiles.py](../../render/xyz_tiles.py)
**Straßenraumkarte**

PyQGIS metatile renderer: z15-z20, metatile 8, gutter 1, DPI 96, `#ededed` background, PNG/JPEG format switch.

## Notes on coverage gaps

- No public **tippecanoe** golden raster tile suite found; geometry/stat tests only (**unverified** beyond absence in primary repos searched).
- **FLIP Rust crate** not found; Python/C++ only as of 2026-08.
- **Chromium GM test** docs not deeply read; concepts borrowed via Skia Gold only.
- Threshold numbers in summary section 1.9 are **proposed starting points**, not calibrated on this project's QGIS-vs-Rust pairs yet — mark as **unverified** until measured on ~50 reviewed tiles.
