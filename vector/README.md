# Straßenraumkarte · vector output (prep)

PostGIS → GeoJSONSeq → tippecanoe → `.pmtiles`, previewed in MapLibre with a basic geometry-type style.

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
bun run scripts/verify-preview.ts
```

## Style (prep)

| Geometry | Paint |
| --- | --- |
| polygons / multipolygons | transparent blue fill |
| lines | purple |
| points | red circles (detail layers from **z17**) |

QGIS-faithful styling is out of scope for this prep pass — see the vector output channel plan.

## Layout

| Path | Role |
| --- | --- |
| `layers.ts` | Layer list: table, columns, zoom, tippecanoe group, paint kind |
| `scripts/export.ts` | `ogr2ogr` GeoJSONSeq export (`ST_SetSRID(geom,3857)` then transform) |
| `scripts/build-tiles.ts` | tippecanoe per group + `tile-join` |
| `vite.config.ts` | Vite + `/mvt/{z}/{x}/{y}.mvt` middleware reading the PMTiles archive |
| `src/style/basic.ts` | Prep MapLibre style |
| `out/` | GeoJSONSeq + intermediate tiles (gitignored) |
| `public/tiles/` | Final `.pmtiles` (gitignored except `.gitkeep`) |

## Tooling notes (MapLibre 6 + Vite)

- **Browser delivery is HTTP MVT**, not `pmtiles://` protocol: MapLibre 6 loads tiles in a **web worker** where `addProtocol('pmtiles')` does not run. The Vite middleware serves `/mvt/...` via `pmtiles.getZxy` from `public/tiles/strassenraumkarte.pmtiles`.
- **Pin the worker** with `setWorkerUrl(.../maplibre-gl-worker.mjs?url)` and keep `maplibre-gl` in `optimizeDeps.exclude` so Vite does not break the worker path.
- Tippecanoe groups (z15–16 ground, z15–17 streets/buildings/labels, z17–18 detail) match the plan; joined archive is ~13 MiB for the current Berlin extract.
