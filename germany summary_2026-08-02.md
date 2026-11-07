# Germany map capacity / pipeline summary — 2026-08-02

Summer 2026 work on the Straßenraumkarte pipeline focused on performance, codecs, a Rust raster renderer, and a MapLibre vector output channel. Experiments used Berlin extracts and bounding boxes (starter and large-bbox scopes); findings inform scaling toward Germany but do not constitute a national sizing study.

---

## 1. SQL performance explorations

On a large Berlin bounding box, SQL preparation accounts for roughly **1%** of wall time; rendering accounts for **~99%**. SQL optimization is therefore secondary to render throughput.

Documented prep optimizations for [`building.sql`](data/processing/sql/building.sql):

| Step | Effect | Status |
|------|--------|--------|
| Deterministic height picks (`DISTINCT ON`) | Stable digests across runs | Landed |
| Attribute join: `ST_Overlaps OR ST_Within` → `&&` + `ST_Intersects` + `NOT ST_Touches` | ~38 s → ~34 s | Landed |
| `ST_UnaryUnion` approach | Digest drift | Rejected |
| `ST_PointOnSurface` join | ~8× faster join alone, but wrong match set | Rejected |

**Process lesson:** prove repro A == repro B before attributing diffs to optimizations.

**Further reading:** [SQL compare learnings](audit/sql-compare/LEARNINGS.md), [SQL compare README](audit/sql-compare/README.md), [audit overview](audit/README.md), [pipeline performance plan](.cursor/plans/pipeline_performance_optimization.plan.md)

---

## 2. QGIS performance exploration

**Status quo:** production still uses PyQGIS metatile rendering ([`render/xyz_tiles.py`](render/xyz_tiles.py)), default **mt8 gutter1**, **JPG q90**.

**Findings:**

- **Workers:** `workers=2` ≈ **1.6–1.7×** wall-time speedup; 4 workers show little additional gain. SSIM PASS for workers 1↔2.
- **Metatile / gutter:** keep **metatile 8 / gutter 1** — mt4, mt16, and gutter0 fail minimum SSIM thresholds.
- **Fonts:** Open Sans gives quieter, more correct labels; not a material speedup.

**Further reading:** [render-explore results](audit/render-explore/RESULTS.md), [large workers](audit/render-explore/LARGE_WORKERS.md), [metatile notes](audit/render-explore/METATILE.md), [tile-compare results](audit/tile-compare/RESULTS.md), [QGIS rendering internals](research/qgis-rendering-internals/summary.md)

---

## 3. WebP / JPG / PNG explorations

**Role split:**

- **WebP q90** — Rust live farm default (adopted 2026-08-01)
- **JPG q90** — QGIS production default
- **PNG** — regression harness only

**Size (full Berlin bbox z15–z20, ~103,915 tiles):** PNG **826.3 MiB** → WebP q90 **78.4 MiB** (−90.5%); WebP is **~12× smaller** than PNG.

**Quality:** WebP q90 ≈ visually lossless under pixelmatch threshold **0.1** vs PNG.

**Speed:** JPG encoding via the Rust `image` crate is too slow for farm throughput; kept for parity testing only.

**Further reading:** [WebP migration](audit/tile-regression/WEBP_MIGRATION.md), [speed iterations](audit/tile-regression/SPEED_ITERATIONS.md), [Rust renderer evaluation](docs/rust-renderer-evaluation.md)

---

## 4. Rust raster pipeline

**Status quo:** hybrid migration — [`rust/srk-render`](rust/srk-render) replaces the paint step for farm throughput; QGIS remains the visual reference. Full-style visual design does **not** align yet.

**Speed (large Berlin bbox z18–z20, ~102k tiles, 8 workers):** Rust WebP farm **~79 s** vs QGIS **~1568 s** ≈ **~20×** faster.

**Visual parity:**

- `highway_area` isolate: **~0.08%** pixelmatch residual (strong)
- Full-approx: **~10–11%** residual (labels dominate, plus SVG/effects/symbol levels/anti-aliasing gaps)

**Design gaps (not aligned yet):** PAL labels not ported, partial SVG/furniture, incomplete effects, symbol levels, farm gutter 0 vs parity gutter 1. See [STYLE_ITERATE_GAPS](audit/tile-regression/STYLE_ITERATE_GAPS.md) and [evaluation doc](docs/rust-renderer-evaluation.md).

**Tooling:**

- **`srk-render` CLI** — WebP default; presets `full-approx` / `highway_area` ([README](rust/srk-render/README.md))
- **`audit/tile-regression/`** — render-suite, compare, benches ([README](audit/tile-regression/README.md))
- **3-pane compare UI** in [`vector/`](vector/) — `?compare=1&panes=qgis,rust,vector` ([vector README](vector/README.md); walkthrough in [§7](#7-try-it-yourself--nord-neukölln-starter-area))
- **Style IR dump** — [`style/scripts/dump-style.py`](style/scripts/dump-style.py)
- **sql-compare** — freeze PostGIS so diffs are renderer-only ([sql-compare README](audit/sql-compare/README.md))

**Further reading:** [Rust renderer evaluation](docs/rust-renderer-evaluation.md), [Rust raster research](research/rust-raster-map-rendering/summary.md), [full style report](audit/tile-regression/FULL_STYLE_REPORT.md), [speed iterations](audit/tile-regression/SPEED_ITERATIONS.md)

---

## 5. MapLibre vector tiles

**Process:** PostGIS → ogr2ogr GeoJSONSeq → tippecanoe per group → tile-join PMTiles → MapLibre 6 + hand-built style.

**Status quo:** landed as a **second output channel** (not a QGIS replacement). Plan todos complete. Style groups G0–G12 mostly done; G7 parked cars out of scope; roof shape skipped.

**Key notes:**

- [`layers.ts`](vector/layers.ts) is the style contract
- tippecanoe **z15–18** with overzoom to z20
- Berlin archive **~16 MiB**
- Effects/textures are approximations
- Sprite for closed textures + runtime missing-image resolver for unbounded SVGs

**Further reading:** [vector README](vector/README.md), [MapLibre style groups](docs/maplibre-style-groups.md), [vector output channel plan](.cursor/plans/maplibre_vector_output_channel_301665ec.plan.md), [special-case styling research](research/maplibre-special-case-styling/summary.md), [ad-hoc image loading research](research/maplibre-ad-hoc-image-loading/summary.md)

---

## 6. Other work

- **Tile visual-regression methodology** — [research summary](research/tile-visual-regression/summary.md) plus the [`audit/tile-regression/`](audit/tile-regression/) harness
- **Metatile / gutter decisions** — see [QGIS section](#2-qgis-performance-exploration) and [METATILE](audit/render-explore/METATILE.md)
- **Style IR / inventory tooling** — [style/scripts README](style/scripts/README.md)
- **Pipeline performance strategy** — [pipeline performance plan](.cursor/plans/pipeline_performance_optimization.plan.md)

**Scope note:** no dedicated Germany-national research yet. All evidence is Berlin-scoped (starter and large-bbox extracts). National-scale capacity remains an open question, informed by the **~20×** Rust farm speedup and the PMTiles interactive path.

---

## 7. Try it yourself — Nord-Neukölln starter area

Most experiments in this summary use a small **starter bbox** in Nord-Neukölln (~2×2 km, ~278 tiles at z15–18). You can reproduce data prep, raster tiles, vector tiles, and the interactive compare UI locally.

**Prerequisites:** PostgreSQL + PostGIS, osm2pgsql, QGIS (for raster), `ogr2ogr` + tippecanoe + `bun` (for vector). See [main README](README.md) for setup (`./run.sh --setup-db`, `~/.pgpass`). With Docker: [docker/README.md](docker/README.md).

**Starter bbox (WGS84):** `13.4132,52.4715,13.4312,52.4821`

### 1. Prepare data + QGIS raster tiles

From the repo root, with a Berlin PBF (local file or Geofabrik URL):

```bash
./run.sh \
  --data data/osm/berlin-latest.osm.pbf \
  --bbox 13.4132,52.4715,13.4312,52.4821 \
  --zmin 15 --zmax 18
```

Tiles land in `render/tiles/{z}/{x}/{y}.jpg`. Expect a few minutes for SQL + render on this extent.

**Raster-only preview** (no vector):

```bash
./render/preview_server.py
# → http://127.0.0.1:8000/preview.html
```

### 2. Build vector tiles

```bash
cd vector
bun install
PGPASSWORD=… bun run pipeline   # export PostGIS → PMTiles
bun run sprite                  # pack textures into public/sprites/
```

### 3. Start the compare UI

```bash
cd vector
bun run dev
# → http://127.0.0.1:5177
```

| View | URL |
|------|-----|
| Map preview | http://127.0.0.1:5177/#16/52.4768/13.4222 |
| QGIS · Rust · Vector compare | http://127.0.0.1:5177/?compare=1&location=intersection&mode=side-by-side&panes=qgis,rust,vector |
| Debug geometry style | add `?style=debug` or toggle **Debug tile style** in the header |

Vite serves QGIS tiles from `render/tiles/` at `/raster/…`. Toggle panes in the header or via `?panes=`. Modes: side-by-side, swipe, blend.

**Optional — Rust raster pane:** render a reference set first, then point the dev server at it:

```bash
./audit/tile-regression/scripts/render-suite-full.sh
RUST_TILES_ROOT=audit/tile-regression/runs/latest-rust bun run --cwd vector dev
```

Named compare spots (intersection, dense trees, parking street, …) are listed in the header dropdown — see [`vector/locations.ts`](vector/locations.ts).

**Further reading:** [vector README](vector/README.md), [tile-regression README](audit/tile-regression/README.md)

---

## Closing

The pipeline now has a dual-path picture: **QGIS / Rust raster** for reference, print, and farm capacity; **MapLibre / PMTiles** for interactive use. Visual parity on the Rust renderer is the main open item before QGIS can be dropped for production raster output.
