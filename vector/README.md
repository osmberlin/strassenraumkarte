# Straßenraumkarte · vector output (prep)

PostGIS → GeoJSONSeq → tippecanoe → `.pmtiles`, previewed with **react-map-gl/maplibre** and a basic geometry-type style.

## Prerequisites

- Running PostGIS with processed Straßenraumkarte tables (defaults: `localhost:5433` / `strassenraumkarte` / `postgres` — same as `data/db_config.sh`)
- `ogr2ogr` (GDAL), `tippecanoe`, `tile-join`, `bun`
- `PGPASSWORD` (or `~/.pgpass`) for the DB user

## Commands

```bash
cd vector
bun install
bun run export      # PostGIS → out/*.geojsonl
bun run tiles       # tippecanoe groups + tile-join → public/tiles/strassenraumkarte.pmtiles
bun run tile-report # sizes
bun run pipeline    # export + tiles + report
bun run dev         # MapLibre preview at http://127.0.0.1:5177
bun run check       # type-check
```

Optional: export a subset with `bun run export highway_area tree`.

Smoke the map (needs `bun run dev` and Playwright Chromium):

```bash
bun run verify-preview
```

## Style (prep + foundation)

| Geometry | Paint |
| --- | --- |
| polygons / multipolygons | transparent blue fill |
| lines | purple |
| points | red circles (detail layers from **z17**) |

Shared modules under `src/style/`:

| Module | Role |
| --- | --- |
| `metres.ts` | `metresToPixels` / `mmToPixels` (QGIS MapUnit → CSS px) |
| `order.ts` | QGIS paint order + OSM `layer` bucket filters (G0.2: one set per bucket) |
| `source.ts` | vector source zooms, glyphs URL |
| `effects.ts` | `dropShadow` / `innerShadow` / `outerGlow` (+ highway MM blur table) |
| `build-style.ts` | `buildStyle()` → StyleSpecification |
| `basic.ts` | prep geometry-type layers (ordered) |

```bash
bun run validate-style   # validateStyleMin
bun test src/style       # metres + style validation
```


## Zoom (tippecanoe ↔ MapLibre)

| Level | Value | Why |
| --- | --- | --- |
| PMTiles archive / vector `source` | **15–18** | tippecanoe group ranges in `layers.ts` (`SOURCE_MINZOOM` / `SOURCE_MAXZOOM`) |
| Map camera | **15–20** | no empty z14; overzoom z19–20 from parent z18 tiles |
| Style layer `minzoom` | per layer `-Z` | detail from z17; ground/streets/buildings/labels from z15 |

Do **not** set `source.maxzoom` to 20 — MapLibre would request missing z19/z20 tiles. Keep it at the archive max (18) so higher map zooms overscale.

## MapLibre 6 + Vite (required)

Per the [v5→v6 migration guide](https://maplibre.org/maplibre-gl-js/docs/guides/v5-to-v6-migration-guide/) and install docs:

```ts
import { setWorkerUrl, addProtocol } from 'maplibre-gl'
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'
import { Protocol } from 'pmtiles'

setWorkerUrl(workerUrl)
const protocol = new Protocol({ metadata: true })
addProtocol('pmtiles', (req, ac) => protocol.tile(req, ac))
```

Use **`?worker&url`**, not plain `?url` — otherwise the worker chunk is missing shared deps and vector tiles never load.

**react-map-gl ≥ 8.1.2** is required for MapLibre 6 (v6 removed public `map.transform`; older react-map-gl crashed in `transformToViewState` reading `center`). See [visgl/react-map-gl#2598](https://github.com/visgl/react-map-gl/pull/2598).

## React (react-map-gl)

Preview uses `react-map-gl/maplibre`: `<MapProvider>`, declarative `<Source>` / `<Layer>` (no `addSource`/`addLayer`), Map event props (`onLoad` / `onIdle`), and `window.__mainMap` in dev via `exposeMainMapForDebugging`.

## Layout

| Path | Role |
| --- | --- |
| `layers.ts` | Layer list: table, columns, zoom, tippecanoe group, paint kind |
| `scripts/export.ts` | `ogr2ogr` GeoJSONSeq export |
| `scripts/build-tiles.ts` | tippecanoe per group + `tile-join` |
| `src/maplibre-setup.ts` | `setWorkerUrl` + pmtiles `addProtocol` |
| `src/App.tsx` | react-map-gl preview |
| `public/tiles/` | Final `.pmtiles` (gitignored except `.gitkeep`) |
