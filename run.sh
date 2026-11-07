#!/bin/bash
#
# Usage:
#   ./run.sh --data <url|path> [--bbox xmin,ymin,xmax,ymax] [--crs EPSG] [--refresh] [--skip-processing]
#            [--skip-render] [--render-only] [--setup-db] [--project path] [--out dir] [--zmin N] [--zmax N]
#            [--metatile N] [--gutter N] [--dpi N] [--background #rrggbb] [--format webp|png|jpg] [--quality N] [--jobs N|dynamic] [--resume] [--inside]
#
#   ./run.sh --check            # verify tools + database connectivity
#   ./run.sh --setup-db         # create database + PostGIS if missing, then exit
#   ./run.sh --render-only      # skip import and SQL processing; render from the existing DB
#
# Runs data preparation then QGIS XYZ tile rendering for the Straßenraumkarte.
# --data is required for the full pipeline. --bbox is optional.
#

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREP_SCRIPT="$REPO_ROOT/data/data_preparation.sh"
RENDER_SCRIPT="$REPO_ROOT/render/render_tiles.sh"
# Prefer macOS QGIS.app PyQGIS when available (override with QGIS_APP / PYTHON).
# shellcheck source=render/qgis_env.sh
source "$REPO_ROOT/render/qgis_env.sh"
# shellcheck source=data/db_config.sh
source "$REPO_ROOT/data/db_config.sh"
# shellcheck source=log_tee.sh
source "$REPO_ROOT/log_tee.sh"
# shellcheck source=audit/lib.sh
source "$REPO_ROOT/audit/lib.sh"
PYTHON="${PYTHON:-python3}"

DATA=""
BBOX=""
REFRESH="false"
SKIP_PROCESSING="false"
SKIP_RENDER="false"
RENDER_ONLY="false"
SETUP_DB="false"
CHECK_ONLY="false"
PROJECT=""
OUT=""
ZMIN=""
ZMAX=""
METATILE=""
GUTTER=""
DPI=""
BACKGROUND=""
FORMAT=""
QUALITY=""
JOBS=""
RESUME="false"
INSIDE="false"
# CRS default comes from data/db_config.sh (CRS=3857); override with --crs or env.

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [$1] $2"
}

usage() {
  cat <<EOF
Usage:
  $0 --data <url|path> [options]
  $0 --render-only [options]
  $0 --check
  $0 --setup-db

Required for pipeline:
  --data <url|path>              OSM PBF source (URL or local file); not needed with --render-only

Optional:
  --bbox xmin,ymin,xmax,ymax    Limit import extract and tile extent (WGS84)
  --crs <EPSG>                   Project CRS for import/storage (default: $CRS)
  --refresh                      Drop/recreate DB schema before import
  --skip-processing              Import only (skip SQL processing)
  --skip-render                  Skip tile rendering after data preparation
  --render-only                  Skip import and SQL processing; render from the existing DB
  --setup-db                     Create database + enable PostGIS if missing
  --check                        Only verify tools and database, then exit
  --project <path>               QGIS project (default: style/strassenraumkarte.qgz)
  --out <dir>                    Tile output directory (default: render/tiles)
  --zmin / --zmax                Zoom range (defaults: 15 / 20)
  --metatile                     Metatile size (default: 8)
  --gutter                       Extra tiles around each metatile (default: 1; discarded after render)
  --dpi                          Render DPI (default: 96)
  --background #rrggbb           Tile background colour (default: #ededed)
  --format webp|png|jpg          Tile format (default: webp)
  --quality N                    JPEG/WebP quality 0-100 (default: 95; 100 = lossless WebP)
  --jobs N|dynamic               QGIS workers (default: dynamic; 1 = sequential)
  --resume                       Skip metatiles whose tiles are already in --out
  --inside                       Write only tiles fully inside the bbox

Database defaults (override with env): DB_NAME=$DB_NAME DB_USER=$DB_USER DB_HOST=$DB_HOST DB_PORT=$DB_PORT CRS=$CRS
EOF
}

require_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log ERROR "Missing command '$cmd'. $hint"
    return 1
  fi
  log INFO "Found $cmd: $(command -v "$cmd")"
}

database_exists() {
  # Prefer connecting to DB_NAME so ~/.pgpass entries for that DB match
  # (a connection to the maintenance DB "postgres" often has no pgpass line).
  local err
  err=$(psql_base -d "$DB_NAME" -Atc "SELECT 1" 2>&1 >/dev/null) && return 0
  # Distinct "does not exist" vs auth/connectivity failure (German + English).
  if echo "$err" | grep -Eqi 'does not exist|existiert nicht|Invalid catalog name'; then
    return 1
  fi
  # Other errors: treat as "not usable" (caller will surface connection issues).
  return 1
}

check_tools() {
  local ok=0
  local need_qgis="${1:-true}"
  require_cmd psql "Install PostgreSQL client tools." || ok=1
  require_cmd osm2pgsql "Install osm2pgsql (flex/Lua support required)." || ok=1
  require_cmd osmium "Install osmium-tool (needed for --bbox extracts)." || ok=1
  if [[ "$need_qgis" = "true" ]]; then
    if [[ ! -x "$PYTHON" ]] && ! command -v "$PYTHON" >/dev/null 2>&1; then
      log ERROR "Missing Python interpreter '$PYTHON'. Install Python 3 or set QGIS_APP / PYTHON (see render/qgis_env.sh)."
      ok=1
    else
      log INFO "Found Python: $PYTHON"
      if ! "$PYTHON" -c "from qgis.core import QgsApplication" >/dev/null 2>&1; then
        log ERROR "PyQGIS not importable ($PYTHON: from qgis.core import QgsApplication)."
        log ERROR "On macOS, source render/qgis_env.sh or set QGIS_APP to your QGIS.app path."
        ok=1
      else
        log INFO "Found PyQGIS ($PYTHON qgis.core)."
      fi
    fi
  else
    log INFO "Skipping PyQGIS check (--skip-render)."
  fi
  return "$ok"
}

check_database() {
  if ! command -v psql >/dev/null 2>&1; then
    return 1
  fi

  # Use DB_NAME (not maintenance DB "postgres") so ~/.pgpass matches project DB entries.
  local err=""
  if ! err=$(psql_base -d "$DB_NAME" -Atc "SELECT 1" 2>&1 >/dev/null); then
    if echo "$err" | grep -Eqi 'does not exist|existiert nicht|Invalid catalog name'; then
      log ERROR "Database '${DB_NAME}' does not exist."
      log ERROR "Create it with: ./run.sh --setup-db"
    else
      log ERROR "Cannot connect to PostgreSQL at ${DB_HOST}:${DB_PORT} as ${DB_USER} (database '${DB_NAME}')."
      log ERROR "Check that the server is running and ~/.pgpass has a matching line, e.g.:"
      log ERROR "  ${DB_HOST}:${DB_PORT}:${DB_NAME}:${DB_USER}:<password>"
      log ERROR "  or ${DB_HOST}:${DB_PORT}:*:${DB_USER}:<password>"
    fi
    return 1
  fi
  log INFO "PostgreSQL reachable at ${DB_HOST}:${DB_PORT} as ${DB_USER} (database '${DB_NAME}')."

  if ! psql_base -d "$DB_NAME" -Atc "SELECT 1 FROM pg_extension WHERE extname='postgis'" 2>/dev/null | grep -q 1; then
    log ERROR "PostGIS extension is not enabled in '${DB_NAME}'."
    log ERROR "Enable it with: ./run.sh --setup-db"
    return 1
  fi
  log INFO "PostGIS extension is enabled."
  return 0
}

setup_database() {
  log INFO "Setting up database '${DB_NAME}' on ${DB_HOST}:${DB_PORT}..."

  if ! command -v psql >/dev/null 2>&1; then
    log ERROR "Missing command 'psql'."
    exit 1
  fi

  # Creating a DB requires a connection to a maintenance database (usually "postgres").
  # Ensure ~/.pgpass covers it, e.g. host:port:*:user:password or host:port:postgres:user:password
  if ! psql_base -d postgres -Atc "SELECT 1" >/dev/null 2>&1; then
    log ERROR "Cannot connect to PostgreSQL maintenance DB 'postgres' at ${DB_HOST}:${DB_PORT} as ${DB_USER}."
    log ERROR "Add a ~/.pgpass line for it, e.g. ${DB_HOST}:${DB_PORT}:*:${DB_USER}:<password>"
    exit 1
  fi

  if database_exists; then
    log INFO "Database '${DB_NAME}' already exists."
  else
    log INFO "Creating database '${DB_NAME}'..."
    psql_base -d postgres -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
  fi

  log INFO "Ensuring PostGIS extension..."
  psql_base -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgis;"
  log INFO "Database setup completed."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--data requires a value"; usage; exit 1; }
      DATA="$2"
      shift 2
      ;;
    --bbox)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--bbox requires xmin,ymin,xmax,ymax"; usage; exit 1; }
      BBOX="$2"
      shift 2
      ;;
    --crs)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--crs requires an EPSG code (e.g. 3857)"; usage; exit 1; }
      CRS="$2"
      export CRS
      shift 2
      ;;
    --refresh)
      REFRESH="true"
      shift
      ;;
    --skip-processing)
      SKIP_PROCESSING="true"
      shift
      ;;
    --skip-render)
      SKIP_RENDER="true"
      shift
      ;;
    --render-only)
      RENDER_ONLY="true"
      shift
      ;;
    --setup-db)
      SETUP_DB="true"
      shift
      ;;
    --check)
      CHECK_ONLY="true"
      shift
      ;;
    --project)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--project requires a path"; usage; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --out)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--out requires a directory"; usage; exit 1; }
      OUT="$2"
      shift 2
      ;;
    --zmin)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--zmin requires a number"; usage; exit 1; }
      ZMIN="$2"
      shift 2
      ;;
    --zmax)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--zmax requires a number"; usage; exit 1; }
      ZMAX="$2"
      shift 2
      ;;
    --metatile)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--metatile requires a number"; usage; exit 1; }
      METATILE="$2"
      shift 2
      ;;
    --gutter)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--gutter requires a number"; usage; exit 1; }
      GUTTER="$2"
      shift 2
      ;;
    --dpi)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--dpi requires a number"; usage; exit 1; }
      DPI="$2"
      shift 2
      ;;
    --background)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--background requires #rrggbb"; usage; exit 1; }
      BACKGROUND="$2"
      shift 2
      ;;
    --format)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--format requires webp, png or jpg"; usage; exit 1; }
      FORMAT="$2"
      shift 2
      ;;
    --quality)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--quality requires a number 0-100"; usage; exit 1; }
      QUALITY="$2"
      shift 2
      ;;
    --jobs)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--jobs requires dynamic or a number >= 1"; usage; exit 1; }
      JOBS="$2"
      shift 2
      ;;
    --resume)
      RESUME="true"
      shift
      ;;
    --inside)
      INSIDE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log ERROR "Unknown parameter: $1"
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$CRS" =~ ^[0-9]+$ ]]; then
  log ERROR "Invalid --crs / CRS (expected EPSG code): $CRS"
  exit 1
fi
export CRS

if [[ "$CHECK_ONLY" = "true" ]]; then
  log INFO "Checking prerequisites..."
  tools_ok=0
  check_tools || tools_ok=1
  db_ok=0
  check_database || db_ok=1
  if [[ "$tools_ok" -ne 0 || "$db_ok" -ne 0 ]]; then
    log ERROR "Prerequisite check failed. See README.md (Requirements / Setup)."
    exit 1
  fi
  log INFO "All checks passed."
  exit 0
fi

if [[ "$SETUP_DB" = "true" && -z "$DATA" ]]; then
  setup_database
  exit 0
fi

if [[ "$RENDER_ONLY" = "true" && "$SKIP_RENDER" = "true" ]]; then
  log ERROR "--render-only and --skip-render cannot be used together."
  exit 1
fi

if [[ "$RENDER_ONLY" != "true" && -z "$DATA" ]]; then
  log ERROR "--data is required (or use --check / --setup-db / --render-only)."
  usage
  exit 1
fi

if [[ "$RENDER_ONLY" != "true" && ! -f "$PREP_SCRIPT" ]]; then
  log ERROR "Missing data preparation script: $PREP_SCRIPT"
  exit 1
fi

if [[ ! -f "$RENDER_SCRIPT" ]]; then
  log ERROR "Missing render script: $RENDER_SCRIPT"
  exit 1
fi

log INFO "Checking prerequisites..."
NEED_QGIS="true"
[[ "$SKIP_RENDER" = "true" ]] && NEED_QGIS="false"
check_tools "$NEED_QGIS" || { log ERROR "Install missing tools, then retry. See README.md."; exit 1; }

if [[ "$SETUP_DB" = "true" ]]; then
  setup_database
fi

check_database || { log ERROR "Database not ready. Run: ./run.sh --setup-db"; exit 1; }

if [[ "$RENDER_ONLY" = "true" ]]; then
  log INFO "Starting tile rendering from existing database (CRS EPSG:$CRS)..."
  ignored=()
  [[ -n "$DATA" ]] && ignored+=("--data")
  [[ "$REFRESH" = "true" ]] && ignored+=("--refresh")
  [[ "$SKIP_PROCESSING" = "true" ]] && ignored+=("--skip-processing")
  if [[ ${#ignored[@]} -gt 0 ]]; then
    log INFO "Ignoring with --render-only: ${ignored[*]}"
  fi
else
  log INFO "Starting Straßenraumkarte pipeline (CRS EPSG:$CRS)..."

  if perf_enabled && [[ ! -f "$PERF_AUDIT_DIR/meta.json" ]]; then
    PERF_AUDIT_LABEL="${PERF_AUDIT_LABEL:-run.sh}"
    perf_init
  fi
  perf_note "pipeline_config" "pipeline" "{\"data\":\"$DATA\",\"bbox\":\"$BBOX\",\"crs\":\"$CRS\",\"refresh\":\"$REFRESH\",\"skip_processing\":\"$SKIP_PROCESSING\",\"skip_render\":\"$SKIP_RENDER\"}"

  PREP_ARGS=(--data "$DATA" --crs "$CRS")
  [[ -n "$BBOX" ]] && PREP_ARGS+=(--bbox "$BBOX")
  [[ "$REFRESH" = "true" ]] && PREP_ARGS+=(--refresh)
  [[ "$SKIP_PROCESSING" = "true" ]] && PREP_ARGS+=(--skip-processing)

  log INFO "Running data preparation..."
  bash "$PREP_SCRIPT" "${PREP_ARGS[@]}"
fi

if [[ "$SKIP_RENDER" = "true" ]]; then
  log INFO "Skipping render (--skip-render)."
  log INFO "Pipeline completed."
  exit 0
fi

RENDER_ARGS=()
[[ -n "$BBOX" ]] && RENDER_ARGS+=(--bbox "$BBOX")
[[ -n "$PROJECT" ]] && RENDER_ARGS+=(--project "$PROJECT")
[[ -n "$OUT" ]] && RENDER_ARGS+=(--out "$OUT")
[[ -n "$ZMIN" ]] && RENDER_ARGS+=(--zmin "$ZMIN")
[[ -n "$ZMAX" ]] && RENDER_ARGS+=(--zmax "$ZMAX")
[[ -n "$METATILE" ]] && RENDER_ARGS+=(--metatile "$METATILE")
[[ -n "$GUTTER" ]] && RENDER_ARGS+=(--gutter "$GUTTER")
[[ -n "$DPI" ]] && RENDER_ARGS+=(--dpi "$DPI")
[[ -n "$BACKGROUND" ]] && RENDER_ARGS+=(--background "$BACKGROUND")
[[ -n "$FORMAT" ]] && RENDER_ARGS+=(--format "$FORMAT")
[[ -n "$QUALITY" ]] && RENDER_ARGS+=(--quality "$QUALITY")
[[ -n "$JOBS" ]] && RENDER_ARGS+=(--jobs "$JOBS")
[[ "$RESUME" = "true" ]] && RENDER_ARGS+=(--resume)
[[ "$INSIDE" = "true" ]] && RENDER_ARGS+=(--inside)

log INFO "Running tile rendering..."
# CRS remains exported for project_extent.py when --bbox is omitted
bash "$RENDER_SCRIPT" "${RENDER_ARGS[@]}"

log INFO "Pipeline completed."
exit 0
