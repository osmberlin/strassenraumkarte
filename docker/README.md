# Docker (Berlin test setup)

Self-contained PostGIS + data-prep stack for running Straßenraumkarte against Berlin OSM data. Tile rendering stays on the host via the local QGIS.app (see [`render/qgis_env.sh`](../render/qgis_env.sh)).

## Prerequisites

- Docker with Compose v2
- Berlin PBF on disk (or any `.osm.pbf` you point `BERLIN_PBF_SOURCE` at)
- For rendering: [QGIS](https://qgis.org) macOS app (default path `/Applications/QGIS-final-4_0_2.app`)

## One-time setup

```bash
# From repository root
cp docker/.env.example docker/.env
# Optional: edit BERLIN_PBF_SOURCE / passwords / OSM2PGSQL_NUMBER_PROCESSES

./docker/link-berlin-pbf.sh
docker compose -f docker/docker-compose.yml --env-file docker/.env up -d db
```

Host DB defaults match [`data/db_config.sh`](../data/db_config.sh): `localhost:5433`, database `strassenraumkarte`, user `postgres`. If port `5433` is already in use (e.g. another PostGIS container), set `DB_HOST_PORT` in `docker/.env` and use the same port in `DB_PORT` / QGIS / `~/.pgpass` on the host.

For host-side `psql` / QGIS against the container, either:

```text
# ~/.pgpass
localhost:5433:*:postgres:postgres
```

or `export PGPASSWORD=postgres` (same password as in `docker/.env`).

## Link / update the Berlin PBF

[`link-berlin-pbf.sh`](link-berlin-pbf.sh) creates `data/osm/berlin-latest.osm.pbf` as a **symlink** to `BERLIN_PBF_SOURCE` (from the environment or `docker/.env`). The link target is gitignored. It also writes **`BERLIN_PBF_MOUNT`** (absolute path) into `docker/.env` so Compose can bind-mount the real file into the tools container (Docker Desktop does not follow host symlinks that point outside the repo mount).

| Goal | Action |
| --- | --- |
| Point at a different file | Set `BERLIN_PBF_SOURCE` in `docker/.env` (absolute path, or relative to the repo root), then re-run `./docker/link-berlin-pbf.sh` |
| Refresh OSM data | Replace/update the source PBF, keep the same `BERLIN_PBF_SOURCE`, re-run the pipeline with `--refresh` |
| Download fresh Geofabrik Berlin | `curl -L -o /path/to/berlin-latest.osm.pbf https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf`, set `BERLIN_PBF_SOURCE` to that path, re-link |

Default in [`.env.example`](.env.example) points at the sibling extract:

`../osm-processing-pipeline-comparison/data/raw/berlin-latest.osm.pbf`

## Data preparation (in Docker)

`--bbox` is already supported by [`run.sh`](../run.sh) (`xmin,ymin,xmax,ymax` WGS84). For the Berlin test stack, set **`BBOX`** in `docker/.env` (default starter extent below) and use the wrapper:

```bash
./docker/run-berlin.sh
# or override once:
BBOX=13.3924,52.4543,13.4859,52.5009 ./docker/run-berlin.sh
# extra flags are forwarded to run.sh, e.g.:
./docker/run-berlin.sh --skip-processing
```

Defaults: `--setup-db --refresh --skip-render --data data/osm/berlin-latest.osm.pbf --bbox "$BBOX"`.

Starter `BBOX` in [`.env.example`](.env.example): `13.4132,52.4715,13.4312,52.4821`.

### With performance audit

```bash
PERF_AUDIT_LABEL=berlin-starter ./audit/run-with-audit.sh ./docker/run-berlin.sh
```

See [`audit/README.md`](../audit/README.md) for raw `steps.jsonl`, `report.md`, and findings.

Equivalent manual Compose invocation:

```bash
docker compose -f docker/docker-compose.yml --env-file docker/.env run --rm tools \
  ./run.sh --setup-db --refresh --skip-render \
  --data data/osm/berlin-latest.osm.pbf \
  --bbox 13.4132,52.4715,13.4312,52.4821
```

- Omit `--bbox` / clear `BBOX` only if you intentionally import all of Berlin (edit the wrapper or call `run.sh` yourself).
- `OSM2PGSQL_NUMBER_PROCESSES` from `.env` is passed through to osm2pgsql.
- Postgres is tuned for bulk import / PostGIS CPU (`docker/postgres/postgresql.conf`, `shm_size: 2gb`).

## Render tiles (on the host)

Use the same bbox as the import:

```bash
source render/qgis_env.sh
# ensure DB is up and ~/.pgpass / PGPASSWORD is set; match DB_HOST_PORT from docker/.env
export PGPASSWORD=postgres
# shellcheck: load BBOX from docker/.env if present
set -a && source docker/.env && set +a
./render/render_tiles.sh --bbox "${BBOX:-13.4132,52.4715,13.4312,52.4821}" --zmax 19
```

Or full pipeline on the host once tools are installed locally and the Docker DB is reachable:

```bash
source render/qgis_env.sh
export PGPASSWORD=postgres
set -a && source docker/.env && set +a
./run.sh --data data/osm/berlin-latest.osm.pbf --bbox "${BBOX:-13.4132,52.4715,13.4312,52.4821}"
```

Override the QGIS bundle if needed: `export QGIS_APP=/Applications/Your-QGIS.app`.

## Services

| Service | Role |
| --- | --- |
| `db` | PostGIS 17 (`imresamu/postgis:17-3.5-bookworm` — Debian bookworm packages with GEOS 3.11+, required for directed line merge in SQL processing), port `${DB_HOST_PORT:-5433}` |
| `tools` | osm2pgsql, osmium, psql — bind-mounts the repo at `/work` and the Berlin PBF via `BERLIN_PBF_MOUNT` |

```bash
docker compose -f docker/docker-compose.yml --env-file docker/.env down
# wipe DB volume:
docker compose -f docker/docker-compose.yml --env-file docker/.env down -v
```
