# Straßenraumkarte (Street Space Map)

The *Straßenraumkarte* is a map style with a particular focus on the spatial organisation of urban and street space — especially carriageways and objects in the public realm, as well as urban land use. It was developed as a basemap for OpenStreetMap projects in Berlin-Neukölln, but can now be generated for other places as well.

The appeal of the style, which is aesthetically inspired by architectural plans, lies in its detailed depiction of urban environments. It emphasises carriageway surfaces, street furniture, buildings, land-use detail, and parked cars in the street space. Where these features are to be shown for a place, they often first need to be mapped in OpenStreetMap — which can be a labour-intensive process.

Technically, the style combines a QGIS project (with the layer styling) and an involved data pipeline based on osm2pgsql and SQL post-processing that prepares geometries and attributes for rendering.

Note: This repository is a new, modernised version based on an osm2pgsql / SQL / QGIS workflow; the original version (Overpass / Python / QGIS) lives at [osmberlin/strassenraumkarte-neukoelln](https://github.com/osmberlin/strassenraumkarte-neukoelln).

Example of the Straßenraumkarte

## Requirements

The following tools are required to run the data pipeline and tile rendering (package names may vary by distribution):


| Component                           | Purpose                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------------ |
| **PostgreSQL** + client (`psql`)    | Database server and CLI                                                        |
| **PostGIS**                         | Spatial types/functions used by import and SQL processing                      |
| **osm2pgsql**                       | OSM import into PostGIS                                                        |
| **osmium-tool** (`osmium`)          | Optional bbox extracts from a PBF                                              |
| **QGIS** (PyQGIS / Python bindings) | Render XYZ tiles from `style/strassenraumkarte.qgz` via a custom metatile loop |


Optional for interactive styling: open `style/strassenraumkarte.qgz` in the QGIS GUI (same database connection as below).

Default connection and project CRS (override with environment variables or CLI flags):


| Variable  | Default             | Meaning                                                        |
| --------- | ------------------- | -------------------------------------------------------------- |
| `DB_NAME` | `strassenraumkarte` | PostgreSQL database                                            |
| `DB_USER` | `postgres`          | Database user                                                  |
| `DB_HOST` | `localhost`         | Database host                                                  |
| `DB_PORT` | `5433`              | Database port                                                  |
| `CRS`     | `3857`              | Project CRS (EPSG code) for osm2pgsql import / PostGIS storage |


Credentials are normally provided via `[~/.pgpass](https://www.postgresql.org/docs/current/libpq-pgpass.html)`, for example:

```text
localhost:5433:*:postgres:YOUR_PASSWORD
```

Shared defaults live in `data/db_config.sh`.

## Setup

1. **Make sure** the tools listed under Requirements are installed.
2. **Start PostgreSQL** and ensure you can connect with the defaults above (or set `DB_`* / `PGPASSFILE`).
3. **Create the database and enable PostGIS** (helper):
  ```bash
   ./run.sh --setup-db
  ```
   Equivalent manual steps:
4. **Verify** tools and database:
  ```bash
   ./run.sh --check
  ```
5. **QGIS project:** `style/strassenraumkarte.qgz` must point at the same host/port/database and use EPSG:3857 (same as `CRS` / `--crs`, unless you intentionally diverge — see [Rendering + CRS](#rendering--crs)). For headless rendering, authentication uses `~/.pgpass` and `PGUSER` (from `DB_USER` in `data/db_config.sh`) — the project datasources typically omit the username.

Console output from `run.sh`, `data/data_preparation.sh`, and `render/render_tiles.sh` is tee’d to a timestamped file under `[logs/](logs/)` (gitignored). Nested scripts share one log file per run.

## Tile rendering

Tiles are rendered by a custom PyQGIS metatile loop (`[render/xyz_tiles.py](render/xyz_tiles.py)`), not `qgis_process`. Metatiles run in parallel; `--jobs dynamic` (default) scales workers to available RAM (cap `min(CPU−1, 8)`), with a gutter so labels can cross edges. Under memory pressure, extra workers are killed and the metatile size may be halved; crashed workers are re-queued. Use `--resume` to skip tiles already on disk; `render/profile_metatile.py` and `data/diagnose_db.sql` help find slow layers. Smaller extents (individual street corridors or neighbourhoods) usually finish in a few minutes. Whole districts or cities take correspondingly longer — e.g. about 1 hour for Berlin-Neukölln (ca. 20 km²) or about 4 hours for Berlin’s inner city (ca. 180 km²), each measured on a system with 32 GB RAM and an Intel i7-7700HQ (8 threads), for z15–z20.

## Usage



### Full pipeline (process + render)

From the repository root, `run.sh` runs data preparation and then XYZ tile rendering. `--data` is required (Geofabrik URL or local `.osm.pbf`) unless `--render-only` is set. `--bbox` is optional (`xmin,ymin,xmax,ymax` in WGS84); without it, the full PBF is imported and tiles cover the combined data extent.

```bash
# Map for a specific extent from fresh OSM data (example: ~4×5 km / ~20 km² in Berlin-Neukölln)
./run.sh \
  --bbox 13.3924,52.4543,13.4859,52.5009 \
  --data https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf

# An extent from a local OSM pbf file, without z20 (example: small area around Richardplatz, Berlin)
./run.sh \
  --bbox 13.439498,52.472155,13.449776,52.475932 \
  --data data/osm/berlin-latest.osm.pbf \
  --zmax 19

# Map for a full, fresh OSM extract (example: all of Berlin)
./run.sh --data https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf

# Render tiles from the existing database (no import or SQL processing)
./run.sh --render-only --bbox 13.439498,52.472155,13.449776,52.475932 --zmax 19
```

Useful options:


| Option              | Meaning                                                                                                                                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--setup-db`        | Create database + enable PostGIS if missing                                                                                                                                                 |
| `--check`           | Only verify tools and database connectivity                                                                                                                                                 |
| `--crs`             | Project CRS as EPSG code (default: `3857`; normally leave unchanged — see [Rendering + CRS](#rendering--crs))                                                                               |
| `--refresh`         | Drop and recreate the database schema before import                                                                                                                                         |
| `--skip-processing` | Import only (skip SQL processing)                                                                                                                                                           |
| `--skip-render`     | Stop after data preparation                                                                                                                                                                 |
| `--render-only`     | Skip import and SQL processing; render tiles from the existing database (`--data` not required)                                                                                             |
| `--project`         | QGIS project (default: `style/strassenraumkarte.qgz`)                                                                                                                                       |
| `--out`             | Tile output directory (default: `render/tiles`)                                                                                                                                             |
| `--zmin` / `--zmax` | Zoom range for rendering (defaults: 15 / 20)                                                                                                                                                |
| `--metatile`        | Metatile core size (default: 8); with `--jobs dynamic` this is the upper bound and may be halved down to 2 under memory pressure                                                            |
| `--gutter`          | Extra tiles around each metatile for seamless labels/symbols; rendered then discarded (default: 1)                                                                                          |
| `--dpi`             | Render DPI (default: 96)                                                                                                                                                                    |
| `--background`      | Tile background colour as `#rrggbb` (default: `#ededed`)                                                                                                                                    |
| `--format`          | Tile format `webp`, `png` or `jpg` (default: `webp`)                                                                                                                                        |
| `--quality`         | JPEG/WebP quality `0`–`100` (default: `95`; `100` = lossless WebP)                                                                                                                          |
| `--jobs`            | Worker processes: `dynamic` (default; scales to RAM, cap `min(CPU−1, 8)`) or fixed `N` (`1` = sequential). Under memory pressure, extra workers are killed and metatile size may be halved. |
| `--resume`          | Skip metatiles whose core tiles already exist in `--out`                                                                                                                                    |
| `--inside`          | Write only tiles fully inside the bbox (skips edge tiles so a smaller render does not overwrite a larger one).                                                                              |


Tiles are written as XYZ files under `render/tiles/{z}/{x}/{y}.{webp|png|jpg}`.

### Street parking (optional)

Parked vehicles come from street-parking **lines** supplied separately (not from the OSM import). Two sources are supported:

1. **TILDA Parkraum** — export as `data/parking/street_parking.gpkg`. Currently available for Berlin ([TILDA Parkraum Berlin](https://tilda-geo.de/regionen/parkraum-berlin-euvm)); in most other cities this data is not publicly available.
2. [street_parking.py](https://github.com/SupaplexOSM/street_parking.py) — the predecessor script that generates parking lines from OSM; place the line output as `data/parking/street_parking_lines.geojson` or `data/parking/street_parking.geojson`.

Processing looks for these files in that order (GPKG first). If none exist, street-parking tables are dropped and the map is built without parked cars. Do **not** use the point export (`street_parking_points.geojson`); vehicle points are generated in SQL.

When present, these lines are snapped generically to carriageway edges during processing and turned into individual vehicles for rendering. Depending on mapping quality and possible processing errors, the result does not always match the real parking layout at a given place.

### Interactive preview

Serve the tile directory with a small local server that also lists PBFs under `data/osm` and can start `./run.sh` from the map UI (draw a BBOX, pick a local PBF or Geofabrik URL):

```bash
./render/preview_server.py
# open http://127.0.0.1:8000/preview.html
```

The preview page can optionally show classic OSM tiles underneath the Straßenraumkarte, overlay a second local XYZ tile directory for comparison (checkbox + folder picker), and includes a metatile/gutter debug overlay. For tiles-only viewing without the run API, `cd render/tiles && python3 -m http.server 8000` still works.

### Data preparation only

```bash
./data/data_preparation.sh \
  --data https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf \
  --bbox 13.3924,52.4543,13.4859,52.5009 \
  --refresh

# Existing local PBF, full file (no bbox extract)
./data/data_preparation.sh --data osm/berlin-latest.osm.pbf --refresh
```

`osm_import.lua` reads the CRS from the `CRS` environment variable (set by `db_config.sh` / `--crs`).

### Rendering only

The same as `./run.sh --render-only` (optional `--bbox`; without it, the combined PostGIS / project extent is used):

```bash
./render/render_tiles.sh \
  --bbox 13.3924,52.4543,13.4859,52.5009 \
  --metatile 8 \
  --gutter 1 \
  --background '#ededed'

# Without --bbox: render the combined PostGIS / project extent
./render/render_tiles.sh --zmin 16 --zmax 19
```



### Rendering + CRS

**CRS:** EPSG:3857 (Web Mercator) is the standard throughout the pipeline — osm2pgsql import, PostGIS storage, QGIS project, and tile rendering. It should normally **not** be changed. If you do override `--crs` / `CRS`, you must also adapt the QGIS project CRS and **all** layer CRS / projection references. Changing the env/CLI value alone does **not** rewrite `style/strassenraumkarte.qgz` or existing layer definitions in this *.qgz-File.

Under EPSG:3857, SQL processing converts ground metres to map units with an automatic scale factor 1/\cos\varphi derived from the data extent centroid (or `--bbox` mid-latitude). See `data/processing/sql/crs_scale.sql` and `metres()`. For a metric projected CRS (e.g. UTM), the factor is 1.

QGIS styles store ground-metre symbol sizes as **map units** scaled by `@mercator_scale` (same factor). Headless rendering (`[render/xyz_tiles.py](render/xyz_tiles.py)`) sets that project variable from the render extent and draws tiles **directly in EPSG:3857**. In the QGIS GUI, a project macro (`openProject`) sets `@mercator_scale` once from the map canvas centre — enable Python macros under *Settings → Options → General* (or allow when opening the project). Without macros, set the project variable `mercator_scale` manually (≈ 1/\cos\varphi; e.g. Berlin ≈ 1.64).

## Further information about the map (in German)

- Beitrag in den *Kartographischen Nachrichten* / Info und Praxis 3/2022: „Die Neuköllner Straßenraumkarte – Ein detaillierter Plan des öffentlichen Raumes auf Basis freier OpenStreetMap-Geodaten“ (ab Seite 5 / A-10) — [PDF](https://static-content.springer.com/esm/art%3A10.1007%2Fs42489-022-00119-1/MediaObjects/42489_2022_119_MOESM1_ESM.pdf)
- Lightning Talk auf der FOSSGIS-Konferenz 2022 (5 Minuten): „Die Neuköllner Straßenraumkarte – ein hochaufgelöster OSM-Mikro-Mapping-Kartenstil“ — [Recording](https://media.ccc.de/v/fossgis2022-14180-die-neukllner-straenraumkarte-ein-hochaufgelster-osm-mikro-mapping-kartenstil)

