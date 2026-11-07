# Research sources

Bibliography for [summary.md](./summary.md). Summaries are factual overviews of what each source covers; they are not endorsements.

## tiny-skia and CPU rasterization

### [tiny-skia README (Linebender)](https://github.com/linebender/tiny-skia)
**Linebender**

Skia CPU subset in Rust: features (fill, stroke, dash, clip, blend, gradients, patterns), explicit out-of-scope list (no text, no filters, no GPU), quality claim vs Skia, SIMD/performance notes, differences from full Skia (no global alpha, simpler clipping).

### [tiny-skia on crates.io](https://crates.io/crates/tiny-skia)
**crates.io**

Version 0.12.0 (2026-02-02), BSD-3-Clause, Linebender maintainership, `simd`/`png-format`/`no-std-float` features.

### [tiny-skia benchmarks README](https://github.com/linebender/tiny-skia/blob/master/benches/README.md)
**Linebender**

Benchmark methodology vs Skia, cairo, raqote; AVX via `-Ctarget-cpu=haswell`; published results at linebender.github.io/tiny-skia.

### [raqote README](https://github.com/jrmuizel/raqote)
**jrmuizel**

Pure Rust 2D library: paths, strokes, dashes, gradients, clipping, blend modes; used by Servo canvas and optionally resvg.

### [raqote on crates.io](https://crates.io/crates/raqote)
**crates.io**

Version 0.8.5.

## resvg / usvg / SVG

### [resvg README (Linebender)](https://github.com/linebender/resvg)
**Linebender**

SVG renderer architecture (usvg preprocess + render), WASM portability, cross-platform pixel reproducibility, no animations, no native text (fontdb/rustybuzz), project crate ecosystem.

### [resvg on crates.io](https://crates.io/crates/resvg)
**crates.io**

Version 0.47.0 (2026-02-09), Apache-2.0 OR MIT.

### [resvg SVG support table](https://linebender.org/resvg-test-suite/svg-support-table.html)
**Linebender**

Per-feature pass rates across SVG renderers; `feGaussianBlur` ~92% for resvg; comparative baseline.

### [resvg CHANGELOG](https://github.com/linebender/resvg/blob/main/CHANGELOG.md)
**Linebender**

Filter crate merge into resvg 0.47; box blur for `feGaussianBlur` stdDeviation≥2; filter bounding box clipping fix.

### [resvg svg2-changelog](https://github.com/linebender/resvg/blob/main/docs/svg2-changelog.md)
**Linebender**

SVG2 filter support status; `edgeMode` on `feGaussianBlur` not supported; filter-function quirks.

### [resvg issue #437 — edgeMode in feGaussianBlur](https://github.com/linebender/resvg/issues/437)
**linebender/resvg**

Discussion of edge handling (RGBA8 default past edges ≈ edgeMode=none); filter region vs canvas bounds.

### [@resvg/resvg-wasm on npm](https://www.npmjs.com/package/@resvg/resvg-wasm)
**npm**

WASM binary for resvg-js; version 2.6.2; browser init via `initWasm`.

### [resvg-js (thx/resvg-js) README](https://github.com/thx/resvg-js/)
**thx**

napi-rs + wasm-bindgen browser usage; `initWasm` + `Resvg` API; font buffer loading.

## Vello / GPU rasterization

### [vello README](https://github.com/linebender/vello)
**Linebender**

GPU compute 2D renderer via wgpu; alpha status; open issues for blur (#476), glyph caching (#204); WebGPU web target experimental; MSRV 1.88.

### [vello on crates.io](https://crates.io/crates/vello)
**crates.io**

Version 0.9.0.

### [vello_cpu on crates.io](https://crates.io/crates/vello_cpu)
**crates.io**

Version 0.0.9 (2026-05-30), CPU SIMD renderer, `u8_pipeline`/`f32_pipeline`, `text` via glifo, `multithreading` via rayon.

### [vello_cpu docs.rs](https://docs.rs/vello_cpu/latest/vello_cpu/)
**docs.rs**

API overview: `RenderContext`, `Pixmap`, pipeline feature flags, pre-1.0 API stability caveat.

### [vello_hybrid on crates.io](https://crates.io/crates/vello_hybrid)
**crates.io**

Version 0.0.9; hybrid CPU path + GPU composite; `webgl` feature; MSRV 1.88.

### [Linebender in December 2025 (vello_cpu / hybrid updates)](https://linebender.org/blog/tmil-24/)
**Linebender**

Vello family status: CPU, GPU, hybrid renderers; recent perf and determinism fixes in hybrid.

### [lyon README](https://github.com/nical/lyon)
**nical**

Path tessellation for GPU; explicitly not an SVG renderer; no built-in AA.

## Bindings and legacy 2D stacks

### [skia-safe / rust-skia README](https://github.com/rust-skia/rust-skia)
**rust-skia**

Safe Skia bindings; prebuilt binaries per platform; WASM via emscripten only; full Skia feature surface including text and filters.

### [skia-safe on crates.io](https://crates.io/crates/skia-safe)
**crates.io**

Version 0.99.0, MIT.

### [piet README](https://github.com/linebender/piet)
**Linebender**

2D graphics abstraction; maintenance mode; backends cairo/D2D/CoreGraphics; superseded in practice by Vello direction.

### [cairo-rs on crates.io](https://crates.io/crates/cairo-rs)
**crates.io**

Version 0.22.0; GTK-rs Cairo bindings.

### [blend2d-sys on crates.io](https://crates.io/crates/blend2d-sys)
**crates.io**

Version 0.3.0; Rust bindings to Blend2D C++ library.

### [femtovg on crates.io](https://crates.io/crates/femtovg)
**crates.io**

Version 0.26.0; WebGL-oriented 2D for egui ecosystem.

### [pathfinder on crates.io](https://crates.io/crates/pathfinder)
**crates.io**

Version 0.6.5; Servo-era GPU renderer; stale release cadence.

## Text and layout

### [cosmic-text docs.rs](https://docs.rs/cosmic-text/latest/cosmic_text/)
**docs.rs**

Version 0.19.0; harfrust shaping, fontdb, swash rasterization, `SwashCache`, hinting, subpixel bins.

### [cosmic-text on crates.io](https://crates.io/crates/cosmic-text)
**crates.io**

Version 0.19.0 (2026-04-22), MIT OR Apache-2.0.

### [parley README](https://github.com/linebender/parley)
**Linebender**

Rich text layout; Fontique/HarfRust/Skrifa/ICU4X stack; layout and editing, not map labeling.

### [parley on crates.io](https://crates.io/crates/parley)
**crates.io**

Version 0.11.0 (2026-06-26), Apache-2.0 OR MIT.

### [ab_glyph on crates.io](https://crates.io/crates/ab_glyph)
**crates.io**

Version 0.2.32; simple single-font rasterization.

## Effects / blur helpers

### [fastblur on crates.io](https://crates.io/crates/fastblur)
**crates.io**

Version 0.1.1; Gaussian blur helper crate.

### [image on crates.io](https://crates.io/crates/image)
**crates.io**

Version 0.25.10; `imageops::blur` and encode/decode.

### [imageproc on crates.io](https://crates.io/crates/imageproc)
**crates.io**

Version 0.27.0; `gaussian_blur_f32` and other image processing.

## Output encoding

### [zune-jpeg on crates.io](https://crates.io/crates/zune-jpeg)
**crates.io**

Version 0.5.15; pure Rust JPEG encoder.

### [oxipng on crates.io](https://crates.io/crates/oxipng)
**crates.io**

Version 10.1.1; PNG optimizer.

### [mozjpeg on crates.io](https://crates.io/crates/mozjpeg)
**crates.io**

Version 0.10.13; libjpeg-turbo bindings.

## PostGIS / tiles / server projects

### [geozero on crates.io](https://crates.io/crates/geozero)
**crates.io**

Version 0.15.1; WKB/WKT/GeoJSON streaming with PostGIS support.

### [postgis on crates.io](https://crates.io/crates/postgis)
**crates.io**

Version 0.9.0; EWKB decoding to geo-types.

### [tokio-postgres on crates.io](https://crates.io/crates/tokio-postgres)
**crates.io**

Version 0.7.18; async Postgres driver.

### [martin README](https://github.com/maplibre/martin)
**MapLibre**

Blazing fast vector tile server; PostGIS, PMTiles, MBTiles; sprites/fonts/styles; not a QGIS rasterizer.

### [martin on crates.io](https://crates.io/crates/martin)
**crates.io**

Version 1.13.0 (2026-07-25).

### [Martin server-side raster tile rendering](https://maplibre.org/martin/sources-styles/rendering/)
**MapLibre**

Experimental MapLibre style → raster; static image API; Linux only; no cache/concurrency; POST GeoJSON overlay.

### [Martin configuration — styles.rendering](https://maplibre.org/martin/config-file/)
**MapLibre**

`styles.rendering.enabled` flag; experimental performance disclaimer.

### [Martin endpoints](https://maplibre.org/martin/using/)
**MapLibre**

HTTP API including `/style/{style}/{z}/{x}/{y}.{ext}` raster tiles on Linux.

### [t-rex README](https://github.com/t-rex-tileserver/t-rex)
**t-rex-tileserver**

Deprecated MVT vector tile server from PostGIS; no raster; replaced by bbox-tile-server.

### [galileo README](https://github.com/Maximkaaa/galileo)
**Maximkaaa**

Cross-platform wgpu map engine; raster/vector/feature layers; WASM examples; roadmap for PostGIS/WMS; not headless tile factory.

### [galileo on crates.io](https://crates.io/crates/galileo)
**crates.io**

Version 0.2.1 (2025-07-11), MIT OR Apache-2.0.

### [maplibre-rs README](https://github.com/maplibre/maplibre-rs)
**MapLibre**

Rust MapLibre style renderer; WebGPU; proof-of-concept; missing labels, symbols, raster, collision.

### [mvt on crates.io](https://crates.io/crates/mvt)
**crates.io**

Version 0.14.0; vector tile codec.

### [pmtiles on crates.io](https://crates.io/crates/pmtiles)
**crates.io**

Version 0.23.1; PMTiles archive access.

### [tilecover on crates.io](https://crates.io/crates/tilecover)
**crates.io**

Version 2.0.0; tile coverage geometry.

### [walkers on crates.io](https://crates.io/crates/walkers)
**crates.io**

Version 0.56.0; “slippy map widget for egui” — not a tile renderer.

### [mapvas on crates.io](https://crates.io/crates/mapvas)
**crates.io**

Version 0.2.11; “map viewer with drawing functionality”.

## MapLibre Native / alternatives

### [MapLibre Native README](https://github.com/maplibre/maplibre-native)
**MapLibre**

C++ vector map renderer; GPU; Node bindings; Qt bindings in separate repo.

### [MapLibre Native Linux — mbgl-render](https://maplibre.org/maplibre-native/docs/book/platforms/linux/)
**MapLibre**

Building and running `mbgl-render`; headless via `xvfb-run`; static image from style JSON + mbtiles.

### [mbgl-renderer README](https://github.com/consbio/mbgl-renderer)
**consbio**

Node static map renderer using maplibre-gl-native; CLI/HTTP; local mbtiles; xvfb for headless.

### [Martin style rendering roadmap](https://maplibre.org/roadmap/martin-tile-server/style-rendering/)
**MapLibre**

Future direction: CPU rendering with optional MapLibre Native GPU; batch rendering goals.

## WASM / browser

### [wasm-bindgen-rayon on crates.io](https://crates.io/crates/wasm-bindgen-rayon)
**crates.io**

Version 1.3.0; Rayon thread pool in WASM; requires SharedArrayBuffer / COOP+COEP.

### [WebGPU API — MDN](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API)
**MDN**

WebGPU not Baseline as of doc publication; browser support caveats.

### [MapLibre GL JS addProtocol](https://maplibre.org/maplibre-gl-js/docs/API/functions/addProtocol/)
**MapLibre**

Custom URL schemes for tile loading; return ArrayBuffer/ImageBitmap/HTMLImageElement.

### [maplibre-gl-js PR #2393 — addProtocol ImageBitmap/HTMLImageElement](https://github.com/maplibre/maplibre-gl-js/pull/2393)
**maplibre/maplibre-gl-js**

Raster tile loading via addProtocol with image types instead of fetch-only ArrayBuffer.

## Project context (this repo)

### [rust-wasm-geo SKILL](https://github.com/FixMyBerlin/fixmyskills/blob/main/skills/rust-wasm-geo/SKILL.md)
**FixMyBerlin**

Geo computation crates and WASM boundaries; explicitly not pixel generation.

### [maplibre-special-case-styling research](../maplibre-special-case-styling/)
**Straßenraumkarte**

Tone/structure template for this research folder.

## Notes on coverage gaps

- **rustymapper** — no crate found on crates.io; marked unverified in summary.
- **fontdue**, **harfbuzz_rs** — not deeply verified in this pass; cosmic-text/parley/resvg stack preferred.
- **geo-postgis** as separate crate — not found; geozero `with-postgis` feature used instead.
- **Qt vs Skia AA gamma** — no single primary doc compared QGIS `QPainter` to tiny-skia; differences inferred from Qt/Skia architecture docs and tiny-skia README; treat as engineering hypothesis, not measured in this pass.
- **@resvg/resvg-wasm version lag** vs resvg 0.47 — npm shows 2.6.2 (2024); exact resvg version bundled unverified without building the package.
