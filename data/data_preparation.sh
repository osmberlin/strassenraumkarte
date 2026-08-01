#!/bin/bash
#
# Usage:
#   ./data_preparation.sh [--data <url|path>] [--bbox xmin,ymin,xmax,ymax]
#                         [--crs EPSG] [--refresh] [--skip-processing]
#
#   --data              OSM PBF source (URL or local path). If omitted, only SQL processing runs on the existing DB.
#   --bbox              Optional WGS84 extract before import (requires --data). Without --bbox the full PBF is imported.
#   --crs               Project CRS as EPSG code (default: from env CRS / 3857). Used by osm2pgsql Lua import.
#   --refresh           Drop and recreate the public schema before import/processing.
#   --skip-processing   Skip SQL processing steps (import only, if --data is set).
#

# postgres database specifications (override via env: DB_NAME, DB_USER, DB_HOST, DB_PORT, CRS)
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=db_config.sh
source "$DIR/db_config.sh"
# shellcheck source=../audit/lib.sh
source "$DIR/../audit/lib.sh"

# directories
OSM_DATA_DIR="$DIR/osm"
CALLER_PWD=$(pwd)

# lua file for osm2pgsql import
IMPORT_LUA="lua/osm_import.lua"

# parameters
# SQL tuning variables: processing/sql/params/params.sql (included by each script)
DATA_SOURCE="false"     # --data: URL or path to osm pbf. If omitted, only processing on existing DB.
DATA_EXTRACT="false"    # --bbox: optional osmium extract (e.g. 13.3924,52.4543,13.4859,52.5009)
DB_REFRESH="false"      # --refresh: drop/recreate public schema
SKIP_PROCESSING="false" # --skip-processing: skip SQL processing

usage() {
  echo "Usage: $0 [--data <url|path>] [--bbox xmin,ymin,xmax,ymax] [--crs EPSG] [--refresh] [--skip-processing]"
}

# parse long options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data)
      if [[ -z "${2:-}" || "$2" == --* ]]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] --data requires a value." >&2
        usage
        exit 1
      fi
      DATA_SOURCE="$2"
      shift 2
      ;;
    --bbox)
      if [[ -z "${2:-}" || "$2" == --* ]]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] --bbox requires a value (xmin,ymin,xmax,ymax)." >&2
        usage
        exit 1
      fi
      DATA_EXTRACT="$2"
      shift 2
      ;;
    --crs)
      if [[ -z "${2:-}" || "$2" == --* ]]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] --crs requires an EPSG code (e.g. 3857)." >&2
        usage
        exit 1
      fi
      CRS="$2"
      export CRS
      shift 2
      ;;
    --refresh)
      DB_REFRESH="true"
      shift
      ;;
    --skip-processing)
      SKIP_PROCESSING="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] Unknown parameter: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$CRS" =~ ^[0-9]+$ ]]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] Invalid --crs / CRS (expected EPSG code): $CRS" >&2
  exit 1
fi
export CRS

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Start script for updating strassenraumkarte data..."
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Project CRS: EPSG:$CRS"

if [[ "$DATA_EXTRACT" != "false" && "$DATA_SOURCE" = "false" ]]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [WARNING] Passed --bbox, but no --data. Skipping extract."
  DATA_EXTRACT="false"
fi

# resolve local --data paths relative to caller cwd (before cd into data/)
if [[ "$DATA_SOURCE" != "false" && ! "$DATA_SOURCE" =~ ^(http|https|ftp):// ]]; then
  if [[ "$DATA_SOURCE" = /* ]]; then
    :
  elif [[ -e "$CALLER_PWD/$DATA_SOURCE" ]]; then
    DATA_SOURCE="$CALLER_PWD/$DATA_SOURCE"
  elif [[ -e "$DIR/$DATA_SOURCE" ]]; then
    DATA_SOURCE="$DIR/$DATA_SOURCE"
  fi
fi

cd "$DIR"

# check data source:
if ! [ "$DATA_SOURCE" = "false" ]; then
  OSM_FILENAME=$(basename "$DATA_SOURCE")
  OSM_FILE="$OSM_DATA_DIR/$OSM_FILENAME"
  mkdir -p "$OSM_DATA_DIR"

  # if it's an URL, download data
  if [[ "$DATA_SOURCE" =~ ^(http|https|ftp):// ]]; then
    if curl -I -f -L -s -o /dev/null "$DATA_SOURCE"; then
      echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Downloading osm data for data import..."
      perf_step "download_pbf" "ingest" --detail "{\"url\":\"$DATA_SOURCE\"}" -- \
        curl -f -L --progress-bar -o "$OSM_FILE" "$DATA_SOURCE"
    else
      echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] Data source URL "$DATA_SOURCE" isn't valid/reachable. Aborting script."
      exit 1
    fi

  # if it's a local file path, use this data
  elif [[ -e "$DATA_SOURCE" ]]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Using osm file for data import..."
    OSM_FILE="$DATA_SOURCE"
    if [[ -f "$OSM_FILE" ]]; then
      perf_note "input_pbf" "ingest" "{\"path\":\"$OSM_FILE\",\"bytes\":$(wc -c <"$OSM_FILE" | tr -d ' ')}"
    fi

  # abort if no valid data source is passed
  else
    echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] OSM data source "$DATA_SOURCE" isn't existing (neither a URL nor a valid local file path). Aborting script."
    exit 1
  fi

  # if required, extract area of interest from data source
  if ! [ "$DATA_EXTRACT" = "false" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Create osm data extract..."
    EXTRACT_FILE="$OSM_DATA_DIR/extract_$OSM_FILENAME"
    # shellcheck disable=SC2086
    perf_step "osmium_extract" "ingest" --detail "{\"bbox\":\"$DATA_EXTRACT\"}" -- \
      osmium extract -b $DATA_EXTRACT "$OSM_FILE" -o "$EXTRACT_FILE" -O -s smart
    IMPORT_FILE=$EXTRACT_FILE
    if [[ -f "$IMPORT_FILE" ]]; then
      perf_note "extract_pbf" "ingest" "{\"path\":\"$IMPORT_FILE\",\"bytes\":$(wc -c <"$IMPORT_FILE" | tr -d ' ')}"
    fi
  else
    IMPORT_FILE=$OSM_FILE
  fi
fi

# if required, refresh database
if [ "$DB_REFRESH" = "true" ]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Refresh database..."
  perf_step "db_refresh" "import" -- \
    psql_base -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_sfcgal;"
elif ! [[ -z "${IMPORT_FILE:-}" ]]; then
  # Ensure PostGIS is available before import (idempotent)
  perf_step "db_ensure_postgis" "import" -- \
    psql_base -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_sfcgal;" >/dev/null
fi

# import data if valid data source was provided
if ! [[ -z "${IMPORT_FILE:-}" ]]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Importing OSM Data (CRS EPSG:$CRS)..."
  # CRS is read by lua/osm_import.lua via os.getenv("CRS")
  OSM2PGSQL_ARGS=(-c -H "$DB_HOST" -P "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -O flex -S "$IMPORT_LUA")
  if [[ -n "${OSM2PGSQL_NUMBER_PROCESSES:-}" ]]; then
    OSM2PGSQL_ARGS+=(--number-processes "$OSM2PGSQL_NUMBER_PROCESSES")
    echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - osm2pgsql --number-processes $OSM2PGSQL_NUMBER_PROCESSES"
  fi
  perf_step "osm2pgsql_import" "import" --detail "{\"file\":\"$IMPORT_FILE\",\"crs\":\"$CRS\",\"processes\":\"${OSM2PGSQL_NUMBER_PROCESSES:-}\"}" -- \
    osm2pgsql "${OSM2PGSQL_ARGS[@]}" "$IMPORT_FILE"

  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Snapshot import lanes (for segment splitting on re-runs)..."
  perf_step "snapshot_lanes_import" "import" -- \
    psql_base -d "$DB_NAME" -c "DROP TABLE IF EXISTS lanes_import; CREATE TABLE lanes_import AS SELECT * FROM lanes;"
fi

# processing data (bunch of SQL processing steps for rendering and styling)
if [ "$SKIP_PROCESSING" = "true" ]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Skipped OSM Data Processing."
else
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Processing OSM Data..."

  #          + # Script adds new tables only, no changes in existing tables
  #          * # Script changes existing tables
  #      00:00 # Script runtime (MM:SS) – time for processing Neukölln reference area on a reference machine (32 GB RAM, i7-7700HQ × 8 CPU)
  #              (total SQL ~02:56)
  # Dependency # Information about requirements (tables) that must be generated earlier by other scripts

  # Optional mid-latitude from --bbox (WGS84 ymin,ymax → mean) for mercator scale.
  # LC_NUMERIC=C: awk must emit a dot decimal (de_DE would print "52,47…" which PostgreSQL rejects).
  BBOX_MID_LAT=""
  if [[ "$DATA_EXTRACT" != "false" ]]; then
    IFS=',' read -r _bbox_xmin _bbox_ymin _bbox_xmax _bbox_ymax <<< "$DATA_EXTRACT"
    if [[ -n "${_bbox_ymin:-}" && -n "${_bbox_ymax:-}" ]]; then
      BBOX_MID_LAT=$(LC_NUMERIC=C awk -v a="$_bbox_ymin" -v b="$_bbox_ymax" 'BEGIN { printf "%.8f", (a + b) / 2 }')
    fi
  fi

  run_sql() {
    # Pass CRS / optional bbox mid-lat so crs_scale.sql (and others) can read them.
    # ON_ERROR_STOP: abort the pipeline instead of cascading missing-table errors.
    local sql_file="$1"
    local label="${2:-}"
    local detail
    detail=$(python3 -c 'import json,sys; print(json.dumps({"file":sys.argv[1],"label":sys.argv[2]}))' "$sql_file" "$label")
    # shellcheck disable=SC2310
    if ! perf_step "sql:$(basename "$sql_file")" "processing" --detail "$detail" -- \
      psql_base -d "$DB_NAME" \
        -v ON_ERROR_STOP=1 \
        -v crs="$CRS" \
        -v bbox_mid_lat="$BBOX_MID_LAT" \
        -f "$sql_file"
    then
      echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] SQL failed: $sql_file" >&2
      exit 1
    fi
  }

  # + | 00:00 | must run before any metres()/line_offset use
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Derive CRS / Mercator scale factor..."
  run_sql "processing/sql/crs_scale.sql" "Derive CRS / Mercator scale factor"

  # * | 00:04
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Interpolate forest trees..."
  run_sql "processing/sql/tree.sql" "Interpolate forest trees"

  # * | 00:00
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Adjust feature direction..."
  run_sql "processing/sql/feature_direction.sql" "Adjust feature direction"

  # * | 00:00
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Generate textures for pitches..."
  run_sql "processing/sql/pitch.sql" "Generate textures for pitches"

  # * | 00:00 | Dependency: pitch_markings from pitch.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Convert table tennis areas to points..."
  run_sql "processing/sql/table_tennis.sql" "Convert table tennis areas to points"

  # * | 01:12
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Process building outlines..."
  run_sql "processing/sql/building.sql" "Process building outlines"

  # * | 00:05 | Dependency: building_parts from building.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Uniform housenumbers..."
  run_sql "processing/sql/housenumber.sql" "Uniform housenumbers"

  # + | 00:00
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Generate tactile paving..."
  run_sql "processing/sql/tactile_paving.sql" "Generate tactile paving"

  # * | 00:02
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Prepare highway segments..."
  run_sql "processing/sql/highway_preparation.sql" "Prepare highway segments"

  # * | 00:02 | Dependency: highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Split lanes to highway segments..."
  run_sql "processing/sql/lanes_split.sql" "Split lanes to highway segments"

  # + | 00:05 | Dependency: highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Spread dual carriageway branches..."
  run_sql "processing/sql/lanes_spread_dual_carriageway.sql" "Spread dual carriageway branches"

  # * | 00:06 | Dependency: lanes from lanes_split.sql; highway_transformed from lanes_spread_dual_carriageway.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Offset lanes..."
  run_sql "processing/sql/lanes_offset.sql" "Offset lanes"

  # * | 00:07 | Dependency: lanes from lanes_offset.sql; highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Compute lane connectivity (prev/next) ..."
  run_sql "processing/sql/lanes_connectivity.sql" "Compute lane connectivity"

  # * | 00:02 | Dependency: lanes from lanes_connectivity.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Snap lane endpoints to connected neighbours ..."
  run_sql "processing/sql/lanes_connect_endpoints.sql" "Snap lane endpoints"

  # + | 00:02 | Dependency: highway_transformed from lanes_spread_dual_carriageway.sql; highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Create highway areas from centerlines..."
  run_sql "processing/sql/highway_area_centerline.sql" "Create highway areas from centerlines"

  # * | 00:11 | Dependency: highway_areas, highway_junctions from highway_area_centerline.sql; highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Create stop lines (road_marking_stop_lines)..."
  run_sql "processing/sql/road_marking_stop_lines.sql" "Create stop lines"

  # + | 00:03 | Dependency: highway_areas, highway_junctions from highway_area_centerline.sql; road_marking_way stop_line rows from road_marking_stop_lines.sql; lanes from lanes_connect_endpoints.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Clip lanes at junctions (road_marking_lanes_prepare)..."
  run_sql "processing/sql/road_marking_lanes_prepare.sql" "Clip lanes at junctions"

  # * | 00:01 | Dependency: lanes_clipped from road_marking_lanes_prepare.sql; lanes, highway
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Barred area polygons..."
  run_sql "processing/sql/road_marking_barred_area.sql" "Barred area polygons"

  # + | 00:05 | Dependency: lanes_clipped from road_marking_lanes_prepare.sql; lanes, highway
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Separation lines..."
  run_sql "processing/sql/road_marking_separation.sql" "Separation lines"

  # * | 00:10 | Dependency: lanes_clipped from road_marking_lanes_prepare.sql; highway_areas from highway_area_centerline.sql; lanes, highway
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Lane divider markings..."
  run_sql "processing/sql/road_marking_lane_divider.sql" "Lane divider markings"

  # * | 00:00 | Dependency: lanes_clipped from road_marking_lanes_prepare.sql; highway_areas from highway_area_centerline.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Crossing edge markings..."
  run_sql "processing/sql/road_marking_crossing_edge.sql" "Crossing edge markings"

  # * | 00:03 | Dependency: lanes_clipped_for_arrows from road_marking_lanes_prepare.sql; lanes from lanes_connect_endpoints.sql; road_marking_stop_lines.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Turn lane arrows..."
  run_sql "processing/sql/road_marking_arrows.sql" "Turn lane arrows"

  # * | 00:01 | Dependency: lanes_clipped from road_marking_lanes_prepare.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Snap directional road marking nodes..."
  run_sql "processing/sql/road_marking_nodes.sql" "Snap directional road marking nodes"

  # * | 00:01 | Dependency: highway_areas from highway_area_centerline.sql; highway_junctions_clipping_areas from road_marking_lanes_prepare.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Merge centerline areas at junctions..."
  run_sql "processing/sql/highway_area_centerline_junctions.sql" "Merge centerline areas at junctions"

  # * | 00:00 | Dependency: highway_areas from highway_area_centerline_junctions.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Merge centerline areas into highway_area..."
  run_sql "processing/sql/highway_area_merge.sql" "Merge centerline areas into highway_area"

  # * | 00:00 | Dependency: highway_area from highway_area_merge.sql; highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Derive surface for OSM highway_area without surface..."
  run_sql "processing/sql/highway_area_surface.sql" "Derive surface for highway_area"

  # * | 00:01 | Dependency: highway_area from highway_area_merge.sql; highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Derive street class for parking highway_area..."
  run_sql "processing/sql/highway_area_parking_class.sql" "Derive parking street class"

  # * | 00:02 | Dependency: highway_area from highway_area_merge.sql; highway_transformed from lanes_spread_dual_carriageway.sql; lanes
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Parking road markings (outlines + symbols)..."
  run_sql "processing/sql/road_marking_parking.sql" "Parking road markings"

  # * | 00:01 | Dependency: lanes_clipped from road_marking_lanes_prepare.sql; highway_area from highway_area_merge.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Surface colour road markings (lanes + highway_area)..."
  run_sql "processing/sql/road_marking_colour.sql" "Surface colour road markings"

  # * | 00:02 | Dependency: highway_transformed from lanes_spread_dual_carriageway.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Get direction of area polygons (highway, landuse paving_stones/sett, road marking)..."
  run_sql "processing/sql/highway_area_direction.sql" "Area polygon direction"

  # * | 00:01 | Dependency: road_marking_polygon.direction from highway_area_direction.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Generate restriction road marking patterns..."
  run_sql "processing/sql/road_marking_restriction.sql" "Restriction road marking patterns"

  # * | 00:12 | Dependency: highway_area from highway_area_merge.sql; highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Crossing road markings..."
  run_sql "processing/sql/road_marking_crossing.sql" "Crossing road markings"

  # * | 00:02 | Dependency: highway_area from highway_area_merge.sql; crossing_marking_lines_clipped from road_marking_crossing.sql; lanes, highway
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Buffer marking road markings..."
  run_sql "processing/sql/road_marking_buffer_marking.sql" "Buffer marking road markings"

  # + | 00:00 | Dependency: highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Unify service roads..."
  run_sql "processing/sql/service.sql" "Unify service roads"

  # + | 00:01
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Create bridge shadow areas..."
  run_sql "processing/sql/bridge.sql" "Create bridge shadow areas"

  # + | 00:00
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Dissolve water body..."
  run_sql "processing/sql/water_body.sql" "Dissolve water body"

  # + | 00:00 | Dependency: water_body_dissolved from water_body.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Clip waterways..."
  run_sql "processing/sql/waterway.sql" "Clip waterways"

  # + | 00:02 | Dependency: water_body_dissolved from water_body.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Create geometries for waterway labeling..."
  run_sql "processing/sql/label_waterway.sql" "Waterway labeling geometries"

  # + | 00:10 | Dependency: highway from highway_preparation.sql
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO]    - Create geometries for highway labeling..."
  run_sql "processing/sql/label_highway.sql" "Highway labeling geometries"

fi

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Script completed."
exit 0