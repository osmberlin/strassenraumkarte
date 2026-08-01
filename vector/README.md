# Straßenraumkarte · vector output

PostGIS → GeoJSONSeq → tippecanoe → `.pmtiles`, styled with a MapLibre port of the QGIS cartography, plus a raster/vector compare harness.

## Prerequisites

- Running PostGIS with processed Straßenraumkarte tables (defaults: `localhost:5433` / `strassenraumkarte` / `postgres` — same as `data/db_config.sh`)
- `ogr2ogr` (GDAL), `tippecanoe`, `tile-join`, `bun`
- `PGPASSWORD` (or `~/.pgpass`) for the DB user
- Optional for compare: QGIS tiles under `render/tiles/` (Vite serves them at `/raster/…`; `./render/preview_server.py` on `:8000` is only needed for the standalone QGIS preview UI)

## Workflow

```bash
cd vector
bun install
PGPASSWORD=… bun run pipeline   # export + tiles + report
bun run sprite                  # pack style/textures → public/sprites/
bun run validate-style          # validateStyleMin
bun run dev                     # http://127.0.0.1:5177
```

Preview: http://127.0.0.1:5177/#16/52.4768/13.4222  
Compare: http://127.0.0.1:5177/?compare=1&location=intersection&mode=side-by-side  

```bash
bun run screenshots   # needs dev (+ raster server) → compare-output/index.html
bun run e2e           # console-clean Playwright across compare locations
bun run check         # type-check + validate-style + unit tests
```

## Tippecanoe flags

Groups in `layers.ts` with `-r1 --no-tiny-polygon-reduction --simplification=2 --preserve-input-order` (prep also used `--no-tile-compression` for easier debugging). Deliberately **not** `--drop-densest-as-needed`. Empty exports get a ~10 m stub feature so tippecanoe still registers the source-layer (MapLibre errors on missing layers).

Measured Berlin extract (joined archive ~16 MiB with styled columns): ground ~0.9 MiB, streets ~2.4 MiB, buildings ~21 MiB, detail ~6.7 MiB, labels ~0.6 MiB.

## Zoom (tippecanoe ↔ MapLibre)

| Level | Value | Why |
| --- | --- | --- |
| PMTiles archive / vector `source` | **15–18** | tippecanoe group ranges (`SOURCE_MINZOOM` / `SOURCE_MAXZOOM`) |
| Map camera | **15–20** | overzoom z19–20 from parent z18 tiles |
| Style layer `minzoom` | per layer `-Z` | detail from z17 |

Do **not** set `source.maxzoom` to 20 — MapLibre would request missing tiles.

## Metres → pixels

QGIS MapUnit sizes use `@mercator_scale`. MapLibre paints CSS px on 512 tiles:

`px = m * 2^z / (78271.51696 * cos φ)` → `metresToPixels` / `metresToPixelsFromProp` (`src/style/metres.ts`). Paper MM (highway blur stack) use `mmToPixels` (96 DPI). Never nest zoom interpolates — bake scales into stop values.

## Effects vs QGIS

| QGIS | MapLibre approximation | Known deviation |
| --- | --- | --- |
| dropShadow | translated fill + blurred outline | softer / weaker on large offsets |
| innerShadow | negative `line-offset` + `line-blur` | banded vs continuous |
| outerGlow | two stacked blurred outlines | join artefacts if too wide |
| Shapeburst / gradients | 2–3 inward blurred `line` bands (`shore_m`) | roof shape skipped (experimental magma/#990003); water depth green ramp omitted; shoreline banded |
| RasterFill textures | `fill-pattern` from sprite | no per-feature rotation / ground-metre scale (G1 surface table) |
| pitch_markings SvgMarker | `symbol` + packed `pitches/*` | uniform `icon-size` from `dist_long`; no independent aspect-fit |
| SvgMarker traffic signs | `setMissingStyleImageResolver` | icons only when style requests them |

## Style modules

| Module | Role |
| --- | --- |
| `layers.ts` | Export columns, tippecanoe zooms/groups |
| `metres.ts` / `effects.ts` / `order.ts` | Scale, shadows/glows, OSM `layer` buckets |
| `colors.ts` + `layers/*` | QGIS-faithful paints (w4c) |
| `scripts/build-sprite.ts` | Texture atlas `@1x`/`@2x` |
| `locations.ts` + `src/compare/` | Compare viewpoints + UI |

## MapLibre 6 + Vite

Worker: `import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'` then `setWorkerUrl(workerUrl)`.  
PMTiles: `addProtocol('pmtiles', …)`.  
react-map-gl **≥ 8.1.2** for MapLibre 6 camera API.
