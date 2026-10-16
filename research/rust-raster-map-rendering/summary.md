# Rust raster map rendering for Straßenraumkarte

Decision-oriented research for replacing the PyQGIS raster tile renderer with a Rust implementation. Input: PostGIS geometries + a style definition (derived from the existing QGIS project). Output: XYZ raster tiles (z15–z20, 256 px, metatile 8 + 1-tile gutter, 96 DPI, JPEG/PNG).

The cartography is heavy (~64 layers, ~800 rule-based rules, ~137 paint effects, ~228 SVG symbols, QGIS labeling). Symbol sizes are ground metres in EPSG:3857 scaled by `@mercator_scale`.

---

## 1. Choosing a rasterizer

### Problem

Straßenraumkarte needs a 2D raster backend that supports: high-quality anti-aliased fills and strokes (caps, joins, miters, dashes), even-odd and non-zero fill rules, clipping, blend modes, solid/gradient/pattern fills, image compositing, and enough throughput for dense urban tiles at z20.

### Why it is hard

No single pure-Rust crate is a drop-in QGIS/Qt replacement. Qt uses its own raster paint engine; QGIS layers Skia-like effects on top. Rust options split into **CPU pixmap painters** (tiny-skia, raqote, skia-safe CPU), **GPU compute painters** (vello, femtovg), and **bindings to C++ engines** (skia-safe, cairo-rs, blend2d-sys).

### CPU rasterizer comparison

| Crate | Version | Licence | Maintainer / status | API model | WASM | Fit for Straßenraumkarte |
| --- | --- | --- | --- | --- | --- | --- |
| [tiny-skia](https://crates.io/crates/tiny-skia) | 0.12.0 (2026-02) | BSD-3-Clause | [Linebender](https://github.com/linebender/tiny-skia); active | Immediate-mode `Pixmap` fill/stroke/clip/blend | Yes (no-std, `simd` feature) | **Best pure-Rust CPU base** — Skia algorithms, AA stroking, dashes, gradients, patterns; no built-in filters |
| [raqote](https://crates.io/crates/raqote) | 0.8.5 | MIT | [jrmuizel](https://github.com/jrmuizel/raqote); low churn | `DrawTarget` paths + paints | Yes (pure Rust) | Usable but [tiny-skia README](https://github.com/linebender/tiny-skia) documents weaker AA (hairlines), slower benchmarks, gradient bugs |
| [vello_cpu](https://crates.io/crates/vello_cpu) | 0.0.9 (2026-05) | Apache-2.0 OR MIT | Linebender; **pre-1.0 API** | `RenderContext` scene → `Pixmap` | Possible (`libm`, no `multithreading`) | Promising but API unstable; text via `glifo` feature only |
| [skia-safe](https://crates.io/crates/skia-safe) | 0.99.0 | MIT | [rust-skia](https://github.com/rust-skia/rust-skia); active | Full Skia `Canvas` API | `wasm32-unknown-emscripten` only ([README](https://github.com/rust-skia/rust-skia)) | **Closest feature parity** (filters, text, effects) but large native build; not `wasm32-unknown-unknown` |
| [cairo-rs](https://crates.io/crates/cairo-rs) | 0.22.0 | MIT | gtk-rs; bindings | Cairo context | Via cairo C build | Mature; system dep; different AA/stroke model than Skia |
| [blend2d-sys](https://crates.io/crates/blend2d-sys) | 0.3.0 | Zlib | Rust bindings to Blend2D C++ | Blend2D context | unverified | JIT rasterizer; less Rust ecosystem integration |
| [piet](https://crates.io/crates/piet) / [piet-common](https://crates.io/crates/piet-common) | 0.6.x | Apache-2.0 OR MIT | Linebender; **[maintenance mode](https://github.com/linebender/piet)** | Trait over cairo/D2D/CoreGraphics | Limited | Abstraction layer, not a renderer; superseded by Vello direction |
| [pathfinder](https://crates.io/crates/pathfinder) | 0.6.5 | Apache-2.0 OR MIT | Servo-era; **stale** (last release years ago) | GPU path renderer | Was WebGL-focused | Not maintained for new work |
| [imageproc](https://crates.io/crates/imageproc) | 0.27.0 | MIT | Community | Image ops on `image` crate | Yes | Not a vector rasterizer; useful for post-process blur |

### GPU rasterizer comparison

| Crate | Version | Licence | Status | WASM / WebGPU | Determinism | Fit |
| --- | --- | --- | --- | --- | --- | --- |
| [vello](https://crates.io/crates/vello) | 0.9.0 | Apache-2.0 OR MIT | **Alpha** ([README warning](https://github.com/linebender/vello)) | WebGPU via wgpu; [web demo](https://linebender.github.io/vello); not primary target | GPU stroke artifacts noted ([#1323](https://github.com/linebender/vello/issues/1323)) | High throughput scenes; **blur/filters not done** ([#476](https://github.com/linebender/vello/issues/476)) |
| [vello_hybrid](https://crates.io/crates/vello_hybrid) | 0.0.9 | Apache-2.0 OR MIT | Pre-1.0 | `webgl` feature for browsers | Same family as Vello | CPU path setup + GPU composite; still missing QGIS-style effects |
| [femtovg](https://crates.io/crates/femtovg) | 0.26.0 | MIT / Apache-2.0 | Active (egui ecosystem) | **Designed for WASM/WebGL** | GPU — not bit-exact | UI/icon rendering, not map-tile batch |
| [galileo](https://crates.io/crates/galileo) | 0.2.1 | MIT OR Apache-2.0 | WIP ([roadmap](https://github.com/Maximkaaa/galileo)) | wgpu → WASM | GPU | **Client map engine**, not headless QGIS-style tile server |
| [lyon](https://crates.io/crates/lyon) | 1.0.19 | Apache-2.0 OR MIT OR MPL-2.0 | Active | N/A (tessellation only) | N/A | Path → triangles for a **custom GPU pipeline**; [no built-in AA](https://github.com/nical/lyon) |

### tiny-skia detail (recommended CPU core)

[tiny-skia](https://github.com/linebender/tiny-skia) is a Skia CPU subset: fills, strokes (caps/joins/miter limit/dash), clipping, blend modes, gradients, patterns, PNG load/save. [SIMD via `simd` feature](https://crates.io/crates/tiny-skia); optional `png-format`. Works without `std`.

**Explicit gaps vs Skia/QGIS** ([README out-of-scope](https://github.com/linebender/tiny-skia)):

- No text rendering ([#1](https://github.com/linebender/tiny-skia/issues/1))
- No image filters (blur, shadow, glow)
- No global layer opacity (only `Pattern` opacity — adjust color alpha manually)
- No bilinear+mipmap downscale
- Simpler clipping (alpha mask vs Skia’s optimized clip stack)
- RGBA8888 only

**Quality claim:** “Unless there is a bug, tiny-skia must produce exactly the same results as Skia” for its supported subset — useful baseline, but QGIS uses Qt’s painter, not Skia directly.

**Performance:** [Benchmarks](https://linebender.github.io/tiny-skia/x86_64.html) show 20–100% slower than Skia on x86-64, still faster than cairo/raqote in many cases. `RUSTFLAGS="-Ctarget-cpu=haswell"` recommended for AVX.

### Solution (rasterizer)

1. **Primary:** `tiny-skia` `Pixmap` as the tile framebuffer.
2. **SVG symbols:** rasterize via `resvg` → blit into pixmap (chapter 2).
3. **Paint effects:** custom multi-pass blur/shadow on pixmaps (chapter 3) — tiny-skia has no filter graph.
4. **Labels:** separate text stack (chapter 4).
5. **Fallback if pixel-match with QGIS proves impossible on effects:** evaluate `skia-safe` CPU canvas (filters, drop shadow APIs) accepting build complexity.
6. **Defer:** Vello/vello_cpu until blur API lands and API stabilizes.

---

## 2. SVG symbols

### Problem

~185 `SvgMarker` symbol layers (~228 SVG assets) must render at arbitrary map scales and rotations.

### Why it is hard

SVG is a full document format; QGIS SVG markers may include filters, gradients, and embedded text. Rust must parse, simplify, and rasterize without system font dependencies.

### resvg / usvg stack

| Crate | Version | Licence | Role |
| --- | --- | --- | --- |
| [resvg](https://crates.io/crates/resvg) | 0.47.0 (2026-02) | Apache-2.0 OR MIT | SVG → pixmap renderer |
| [usvg](https://github.com/linebender/resvg/tree/main/crates/usvg) | (bundled with resvg) | Apache-2.0 OR MIT | Parse/normalize SVG → simplified tree |
| [tiny-skia](https://crates.io/crates/tiny-skia) | 0.12.0 | BSD-3-Clause | resvg’s default backend |
| [rustybuzz](https://github.com/harfbuzz/rustybuzz) | (resvg dep) | MIT | Text shaping in SVG |
| [fontdb](https://github.com/RazrFalcon/fontdb) | (resvg dep) | MIT / Apache-2.0 | In-memory font DB; CSS-like queries |

**Architecture:** Parsing (`usvg::Tree`) is separate from rendering (`resvg::render`). You can cache parsed trees per symbol file.

**Text in SVG:** resvg does **not** use native OS text rendering ([README limitations](https://github.com/linebender/resvg)); it shapes with rustybuzz and rasterizes glyphs. Fonts must be supplied via `fontdb` (embed TTF/OTF or load from disk). Matches server-side determinism goals.

**WASM:** resvg is [“guaranteed to work everywhere you can compile Rust, including WASM”](https://github.com/linebender/resvg). Browser wrapper: [@resvg/resvg-wasm](https://www.npmjs.com/package/@resvg/resvg-wasm) (resvg-js; latest **2.6.2**, published 2024 — **lagging resvg 0.47**).

**Filter support:** [SVG support table](https://linebender.org/resvg-test-suite/svg-support-table.html) shows `feGaussianBlur` at ~92% pass rate for resvg. `feDropShadow` supported (SVG2). `edgeMode` on `feGaussianBlur` **not** supported ([svg2-changelog](https://github.com/linebender/resvg/blob/main/docs/svg2-changelog.md)).

**Reproducibility:** resvg claims [identical pixels across platforms](https://github.com/linebender/resvg) when built without system deps — good for regression tests.

### Solution

1. Pre-convert QGIS SVG marker library to cached `usvg::Tree` at build/startup.
2. Render symbol instances with `resvg` into a small `Pixmap`, apply map rotation/scale, composite onto tile with tiny-skia `PixmapPaint` (filter quality: use `tiny_skia::FilterQuality` — no mipmap path).
3. Ship fonts used inside SVGs in the renderer bundle; mirror QGIS font paths.
4. Golden-test each SVG against current QGIS PNG output at representative scales.

---

## 3. Effects: blur, drop shadow, outer glow

### Problem

~137 enabled QGIS paint effects: drop shadow, inner shadow, outer glow, blur. tiny-skia has **no image filter graph**.

### Why it is hard

QGIS applies effects as a post-process on symbol layers (offset, blur radius, color, blend). Replicating this requires either (a) a filter engine, (b) multi-pass pixmap blur + composite, or (c) Skia-grade `ImageFilter` APIs.

### Option A — Custom CPU passes on `tiny_skia::Pixmap`

Pipeline per affected layer:

1. Render layer (or symbol) to an offscreen `Pixmap` with padding for blur radius.
2. Apply separable Gaussian or stack blur on the alpha channel (or premultiplied RGBA).
3. Offset, tint, blend onto main tile (`BlendMode` supported in tiny-skia).

| Crate / API | Version | Notes |
| --- | --- | --- |
| [fastblur](https://crates.io/crates/fastblur) | 0.1.1 | Gaussian blur on images; verify performance on 256×256 |
| [image::imageops::blur](https://docs.rs/image/latest/image/imageops/fn.blur.html) | via `image` 0.25.10 | Box-blur approximation; fast, not true Gaussian |
| [imageproc::filter::gaussian_blur_f32](https://docs.rs/imageproc/latest/imageproc/filter/fn.gaussian_blur_f32.html) | 0.27.0 | True Gaussian; heavier |
| Hand-rolled stack blur | — | Common for drop shadows; O(n) per pass |

**resvg filter code:** Gaussian blur in resvg uses an **IIR blur for small `stdDeviation`** and switches to **box blur for `stdDeviation >= 2`** ([CHANGELOG](https://github.com/linebender/resvg/blob/main/CHANGELOG.md)) for 4–8× speedup. The `usvg::filter` module is internal to resvg; extracting it means vendoring or depending on resvg’s filter path — not a standalone crate today (filters crate was merged into resvg in 0.47).

**Drop shadow / outer glow:** Compose as: render shape → blur alpha → colorize → offset → `BlendMode::Normal` or `Plus` onto destination. Inner shadow: clip destination, invert mask logic. Match QGIS parameters (blur radius, spread, offset angle/distance) empirically.

### Option B — skia-safe `ImageFilter`

skia-safe exposes Skia’s native blur, drop shadow, and color filters — closest to “it just works” if Qt/Skia visual match is required. Trade-off: C++ Skia build, larger binary, harder WASM story.

### Option C — Vello (future)

[Blur/filters tracked as open work](https://github.com/linebender/vello/issues/476). Not viable for Straßenraumkarte effects today.

### Solution

1. Implement **stack blur or separable Gaussian** on `Pixmap` data (`data_mut()` + `PremultipliedColorU8`).
2. Build a small effect graph mirroring QGIS effect order (shadow below source, glow above, etc.).
3. Use resvg’s filter semantics only for **SVG-embedded** filters, not for map layers.
4. Profile: 137 effects × thousands of features per metatile may dominate — consider effect batching and caching static symbol shadows.

---

## 4. Text and labels

### Problem

QGIS labeling (PAL — automatic placement, collision avoidance, curved labels, priorities) is a major part of the visual identity. Straßenraumkarte has QGIS labeling rules beyond simple point callouts.

### Why it is hard

**Rendering** text (glyph → pixmap) and **placing** labels (global optimization) are separate hard problems. No Rust library matches [QGIS PAL](https://docs.qgis.org/).

### Text shaping and rasterization

| Crate | Version | Licence | Shaping | Rasterization | Notes |
| --- | --- | --- | --- | --- | --- |
| [cosmic-text](https://crates.io/crates/cosmic-text) | 0.19.0 | MIT OR Apache-2.0 | harfrust | swash scaler | Full layout + `SwashCache`; subpixel bins; [hinting enum](https://docs.rs/cosmic-text/latest/cosmic_text/enum.Hinting.html) |
| [parley](https://crates.io/crates/parley) | 0.11.0 | Apache-2.0 OR MIT | HarfRust | (layout only; rasterize via Skrifa paths) | Linebender layout; no map placement |
| [rustybuzz](https://github.com/harfbuzz/rustybuzz) | (resvg dep) | MIT | HarfBuzz subset | — | Used inside resvg for SVG text |
| [ab_glyph](https://crates.io/crates/ab_glyph) | 0.2.32 | Apache-2.0 | No (single font) | Built-in rasterizer | Simple; no complex scripts |
| [fontdue](https://crates.io/crates/fontdue) | — | MIT | No | CPU bitmap | Games/UI; unverified version in this pass |
| [harfbuzz_rs](https://crates.io/crates/harfbuzz_rs) | — | MIT | HarfBuzz bindings | — | System HarfBuzz dep |

**Qt/QPainter match:** Unlikely to be pixel-identical. Qt uses its own text engine (FreeType + proprietary hinting paths). cosmic-text/swash gives deterministic, cross-platform output — aim for **visual parity** not bit identity. Control: font files (same TTF as QGIS), hinting mode, subpixel positioning off for tile tests.

### Label placement

| Project | Role | Map label placement? |
| --- | --- | --- |
| QGIS PAL | Reference | Yes — global optimization |
| MapLibre GL / Native | Client-side | Yes — collision grid, symbol-sort-key; **different model** than PAL |
| [maplibre-rs](https://github.com/maplibre/maplibre-rs) | Rust MapLibre renderer | **Missing:** labels, symbols, collision ([# README](https://github.com/maplibre/maplibre-rs)) |
| [galileo](https://github.com/Maximkaaa/galileo) | Rust map engine | Vector tile styling; **no PAL equivalent** |
| [martin](https://maplibre.org/martin/) | Tile server | Serves glyphs/sprites; does not run PAL |

No maintained Rust crate ports MapLibre’s `symbol-placement: line` engine for offline tile baking. Practical approaches:

1. **Precompute label positions** in PostGIS or offline (centroid, line midpoint, curved text samples) and treat as point/linestring draw ops — loses dynamic collision.
2. **Port simplified PAL** (grid collision + priority queues) — significant engineering.
3. **Keep labels in QGIS** for phase 1; Rust renderer does symbology only.
4. **Export label layers** as point features with rotation/size attributes from QGIS for static tiles.

### Solution

1. **Rendering:** cosmic-text `Buffer` + `SwashCache` → draw glyphs into tiny-skia `Pixmap`.
2. **Placement:** treat as a separate milestone; expect largest visual gap vs current tiles.
3. For regression: compare label-free tiles first, then add placement incrementally.

---

## 5. Reading PostGIS from Rust

### Problem

Renderer must query clipped geometries + attributes per tile (or metatile) from the existing PostGIS schema.

### Tile / data plumbing crates

| Crate | Version | Role |
| --- | --- | --- |
| [martin](https://crates.io/crates/martin) | 1.13.0 | MVT tile **server** from PostGIS; not QGIS-style raster |
| [t-rex](https://github.com/t-rex-tileserver/t-rex) | unmaintained | MVT only; [replaced by bbox](https://www.bbox.earth/docs/tile-server/) |
| [mvt](https://crates.io/crates/mvt) | 0.14.0 | Encode/decode Mapbox Vector Tiles |
| [geozero](https://crates.io/crates/geozero) | 0.15.1 | WKB/WKT/GeoJSON streaming; PostGIS feature |
| [postgis](https://crates.io/crates/postgis) | 0.9.0 | WKB ↔ `geo-types` |
| [tokio-postgres](https://crates.io/crates/tokio-postgres) | 0.7.18 | Async Postgres driver |
| [sqlx](https://crates.io/crates/sqlx) | — | Async SQL + optional PostGIS types |
| [flatgeobuf](https://crates.io/crates/flatgeobuf) | — | File streaming; not live DB |
| [pmtiles](https://crates.io/crates/pmtiles) | 0.23.1 | PMTiles archive I/O |
| [tilecover](https://crates.io/crates/tilecover) | 2.0.0 | Tile bounding coverage math |

### Recommended read path

1. **Server:** `tokio-postgres` or `sqlx` with `ST_AsBinary(ST_ClipByBox2D(geom, !bbox!))` per layer — mirror current SQL tile bounds.
2. **WKB decode:** `geozero::wkb::read_wkb` or `postgis::ewkb` into `geo` types, then convert to `tiny_skia_path::Path` (manual or via [lyon](https://github.com/nical/lyon) for tessellation if needed).
3. **Do not** route through MVT for the bespoke renderer unless you want a MapLibre-style pipeline — MVT loses QGIS rule-based styling unless you re-encode all rules into attributes.

**geozero** is the right abstraction for streaming many geometries through a pipeline ([docs](https://docs.rs/geozero/latest/geozero/)); enable its `with-postgis` / WKB features per your schema.

### Existing “Mapnik/QGIS style raster server” in Rust?

| Project | Raster tiles? | Notes |
| --- | --- | --- |
| martin | **Yes (experimental)** | [Server-side style rendering](https://maplibre.org/martin/sources-styles/rendering/) via MapLibre Native — **Linux only**, no cache, style is MapLibre JSON not QGIS |
| t-rex | No | MVT vector only |
| galileo | Client | Renders in app, not batch tile factory |
| Custom | Yes | What Straßenraumkarte would build |

---

## 6. Output encoding

### Problem

Emit JPEG and PNG tiles matching current CDN format; 256×256 (plus gutter crop); 96 DPI metadata less critical than visual quality and file size.

| Crate | Version | Licence | Use |
| --- | --- | --- | --- |
| [image](https://crates.io/crates/image) | 0.25.10 | MIT OR Apache-2.0 | PNG/JPEG encode from raw RGBA |
| [png](https://crates.io/crates/png) | (via image) | MIT OR Apache-2.0 | Low-level PNG |
| [zune-jpeg](https://crates.io/crates/zune-jpeg) | 0.5.15 | MIT OR Apache-2.0 | **Pure Rust JPEG**; good for server |
| [mozjpeg](https://crates.io/crates/mozjpeg) | 0.10.13 | MIT OR Apache-2.0 | libjpeg-turbo bindings; smaller files, native dep |
| [oxipng](https://crates.io/crates/oxipng) | 10.1.1 | MIT | PNG lossless recompression |
| tiny-skia `encode_png` | 0.12.0 | BSD-3-Clause | Built-in when `png-format` enabled |

**tiny-skia → JPEG:** Export `Pixmap` pixels to `image::RgbaImage`, encode with `zune-jpeg` (quality ~85 to match typical map tiles) or `mozjpeg` if binary size matters.

**Metatile gutter:** Render 8×8 tile metatile with 1-tile padding in pixmap space; crop center tiles before encode — same as QGIS workflow.

---

## 7. WASM viability

### Problem

Could the renderer run in the browser (WASM) for on-the-fly tile painting?

### CPU rasterization in WASM

| Component | WASM fit |
| --- | --- |
| tiny-skia | Works (`no_std` + `simd`); primary candidate |
| resvg | [Explicitly supports WASM](https://github.com/linebender/resvg) |
| cosmic-text | Used in WASM projects; font bytes must ship to browser |
| vello_cpu | Possible; heavier; API unstable |

**WASM SIMD:** Enable `wasm32-unknown-unknown` with `-C target-feature=+simd128` for faster blur/fill ([Rust wasm SIMD](https://doc.rust-lang.org/stable/core/arch/wasm32/)). Requires browser support for SIMD128.

**Multithreading:** [wasm-bindgen-rayon](https://crates.io/crates/wasm-bindgen-rayon) 1.3.0 enables Rayon thread pool; requires [SharedArrayBuffer](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer) and cross-origin isolation headers (**COOP/COEP**). Without them, single-threaded only.

**Memory:** A metatile at z20 with gutter is large (thousands of pixels per side). WASM linear memory caps (browser-dependent, often 2–4 GB max) can bite dense urban scenes with many layers and effect buffers.

**Output to canvas:**

- `putImageData` — simple, slower for large buffers.
- `ImageBitmap` + `transferToImageBitmap` — lower copy cost.
- WebGL texture upload — if using femtovg/wgpu path.

### WebGPU / wgpu in browser (2026)

[MDN WebGPU API](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API): **not Baseline** — “does not work in some of the most widely-used browsers.” Chrome/Edge lead; Firefox/Safari improving but uneven.

[Vello README](https://github.com/linebender/vello): WebGPU on web is experimental; wasm32 demo via `cargo run_wasm`. [galileo](https://github.com/Maximkaaa/galileo) compiles to WASM with wgpu (WebGL or WebGPU).

Realistic for Straßenraumkarte in browser: **CPU tiny-skia path first** in WASM; WebGPU only if targeting Chrome-only internal tools.

### MapLibre GL JS consumption

Raster tiles integrate as standard `raster` sources (`tiles: ['https://…/{z}/{x}/{y}.png']`).

For **client-generated** tiles:

- `maplibregl.addProtocol('custom', …)` — return `{ data: ArrayBuffer }`, `ImageBitmap`, or `HTMLImageElement` ([docs](https://maplibre.org/maplibre-gl-js/docs/API/functions/addProtocol/)).
- Blob URL: `URL.createObjectURL(new Blob([pngBytes], { type: 'image/png' }))` for image sources.

WASM renderer would expose `renderTile(z,x,y) -> Uint8Array` via `wasm-bindgen`; JS protocol handler wraps bytes.

### Verdict: WASM for this workload?

**Poor first target.** Straßenraumkarte tiles are among the densest OSM renderings: hundreds of symbol layers, 137 blurs/shadows, z15–z20, metatile rendering. CPU WASM is **orders of magnitude slower** than native and single-threaded unless COOP/COEP is acceptable. Practical sequence:

1. **Native Linux tile server** (batch, parallel Rayon).
2. Optional WASM for **low-zoom preview** or **single-tile debug** in MapLibre.
3. Revisit when/if `vello_cpu` stabilizes and profiling shows acceptable z17+ latency.

---

## 8. Determinism and pixel-diff pitfalls

### Problem

“Identical-looking” tiles need a testing strategy. Bit-identical across runs/platforms is a stronger bar.

### What can be deterministic

| Layer | Determinism |
| --- | --- |
| resvg + tiny-skia (fixed fonts, no system deps) | [Cross-platform identical pixels](https://github.com/linebender/resvg) |
| tiny-skia alone | Same claim vs Skia subset; fixed SIMD flags |
| cosmic-text + embedded fonts | Deterministic if hinting/subpixel fixed |
| zune-jpeg | **Not** bit-identical across versions/quality settings |
| mozjpeg | Non-deterministic DCT optimizations possible |
| GPU (vello/wgpu) | **Non-deterministic** float order; known stroke artifacts |

### QGIS/Qt vs Skia-family differences (expect pixel diffs)

| Topic | QGIS/Qt | tiny-skia / resvg |
| --- | --- | --- |
| AA gamma | Qt’s raster engine; often gamma-correct blending | Skia-derived linear blending in subset |
| Half-pixel alignment | Qt `QPainter` cosmetic pen rules | Skia path snapping |
| Stroke dashes | Qt dash phase at path start | Skia-compatible in tiny-skia (verify phase on closed rings) |
| Miter limit | Qt defaults | Configurable; match QGIS values explicitly |
| Fill rules | Even-odd / winding | Both supported in tiny-skia |
| Text | Qt font engine | cosmic-text/swash — different hinting |
| Blur | QGIS effect radius | Custom blur — tune to match visually |

**Testing approach:**

1. Golden PNG tests per tile fixture at fixed z/x/y.
2. Allow perceptual diff threshold (e.g. ≤2% pixels, SSIM) for AA, not strict `memcmp`.
3. Pin `RUSTFLAGS`, disable parallel non-determinism during golden runs, embed fonts.

---

## 9. Rust map-rendering projects (landscape)

| Project | Licence | Server raster? | Reuse for Straßenraumkarte |
| --- | --- | --- | --- |
| [galileo](https://github.com/Maximkaaa/galileo) | MIT OR Apache-2.0 | No (client wgpu) | Architecture reference; not headless tile factory |
| [maplibre-rs](https://github.com/maplibre/maplibre-rs) | MIT OR Apache-2.0 | No | Incomplete; missing labels/symbols |
| [martin](https://maplibre.org/martin/) | MIT OR Apache-2.0 | **Experimental** MapLibre style → raster | Wrong style model; useful for MVT/fonts/sprites plumbing |
| [walkers](https://crates.io/crates/walkers) 0.56.0 | MIT OR Apache-2.0 | No | egui slippy map widget |
| [mapvas](https://crates.io/crates/mapvas) 0.2.11 | MIT | No | Map viewer + drawing |
| rustymapper | — | **unverified** | No crate on crates.io |

### Alternative: don’t build a bespoke renderer

| Approach | Pros | Cons |
| --- | --- | --- |
| [MapLibre Native](https://github.com/maplibre/maplibre-native) `mbgl-render` | Full style spec, GPU, labels | QGIS rules ≠ MapLibre JSON; huge C++ dep; [xvfb for headless](https://maplibre.org/maplibre-native/docs/book/platforms/linux/) |
| [mbgl-renderer](https://github.com/consbio/mbgl-renderer) (Node) | Static images from GL styles | Node + native; not Rust |
| [Martin style rendering](https://maplibre.org/martin/sources-styles/rendering/) | Rust server, integrated | MapLibre styles only; Linux; perf concerns |

These solve **MapLibre-style** maps, not direct QGIS project replay. Converting `strassenraumkarte.qgz` rules to MapLibre JSON is the `.cursor/plans/maplibre_vector_output_channel` track — orthogonal to bespoke Rust raster.

---

## 10. Recommended stack

### Phase 1 — native tile server (MVP)

| Layer | Choice |
| --- | --- |
| Geometry I/O | `tokio-postgres` + `geozero` / `postgis` WKB → `geo` |
| Tile math | `tilecover` + internal metatile/gutter logic |
| Vector raster | **tiny-skia** 0.12 |
| SVG symbols | **resvg** / **usvg** 0.47 |
| Effects | Custom stack blur / separable Gaussian on `Pixmap`; reference resvg’s box-blur for large radii |
| Text (deferred or simplified) | **cosmic-text** 0.19 + bundled fonts |
| Parallelism | **rayon** per metatile / per layer |
| Encode | **zune-jpeg** + **png** / tiny-skia `encode_png` |
| Orchestration | Rust binary replacing PyQGIS renderer; same PostGIS inputs |

### Phase 2 — quality hardening

- Golden tile regression suite (perceptual diff).
- If effects/text diverge: spike **skia-safe** 0.99 for filter parity.
- Label placement port or hybrid (QGIS exports label points).

### Phase 3 — WASM (optional)

- `wasm-pack` crate wrapping tiny-skia + resvg only.
- `addProtocol` integration in MapLibre GL JS.
- Scope: z15–z16 preview tiles only unless profiling proves otherwise.

### Explicitly not recommended now

- **vello** / **vello_hybrid** — alpha, missing blur ([#476](https://github.com/linebender/vello/issues/476)).
- **raqote** as primary — inferior AA/perf vs tiny-skia per maintainer benchmarks.
- **galileo** / **maplibre-rs** as renderer base — wrong abstraction (client GL, incomplete).
- **Martin raster mode** as QGIS replacement — requires MapLibre style conversion first.

---

## Risks / open questions

1. **Label placement (PAL)** — no Rust equivalent; may block “identical-looking” acceptance without a major placement project or continued QGIS label export.
2. **137 paint effects** — custom blur/shadow on CPU may be too slow at z20 without aggressive caching; skia-safe fallback may be required for parity and performance.
3. **Pixel parity with QGIS/Qt** — tiny-skia matches Skia, not Qt; expect systematic AA/text differences; define acceptance thresholds early.
4. **Style translation** — extracting ~800 QGIS rules into a renderer-neutral style IR is engineering separate from rasterization; not covered here.
5. **@resvg/resvg-wasm lag** — npm package at 2.6.2 may trail resvg 0.47; browser path needs custom wasm-pack build.
6. **Martin experimental raster** — if team pivots to MapLibre styles later, [rendering is Linux-only, no cache, performance concerns](https://maplibre.org/martin/config-file/) per Martin docs.
