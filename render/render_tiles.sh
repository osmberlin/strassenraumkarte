#!/bin/bash
#
# Usage:
#   ./render_tiles.sh [--bbox xmin,ymin,xmax,ymax] [--project path] [--out dir]
#                     [--zmin N] [--zmax N] [--metatile N] [--gutter N]
#                     [--dpi N] [--background #rrggbb] [--format png|jpg]
#
#   --bbox         Optional WGS84 extent (xmin,ymin,xmax,ymax). Without it, combined
#                  project layer extent is used.
#   --project      QGIS project (.qgz/.qgs). Default: <repo>/style/strassenraumkarte.qgz
#   --out          Output directory for XYZ tiles. Default: <repo>/render/tiles
#   --zmin         Minimum zoom (default: 15)
#   --zmax         Maximum zoom (default: 20)
#   --metatile     Metatile size (default: 8)
#   --gutter       Extra tiles around each metatile for labels/symbols (default: 1);
#                  rendered then discarded (not written)
#   --dpi          Render DPI (default: 96)
#   --background   Tile background colour as #rrggbb (default: #ededed)
#   --format       png or jpg (default: jpg)
#
# Rendering uses a custom PyQGIS metatile loop (render/xyz_tiles.py) with
# per-metatile progress. Tiles are rendered directly in EPSG:3857; ground-metre
# symbol sizes use @mercator_scale (1/cos φ).
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# Prefer macOS QGIS.app PyQGIS when available (override with QGIS_APP / PYTHON).
# shellcheck source=qgis_env.sh
source "$SCRIPT_DIR/qgis_env.sh"
# shellcheck source=../data/db_config.sh
source "$REPO_ROOT/data/db_config.sh"
# shellcheck source=../audit/lib.sh
source "$REPO_ROOT/audit/lib.sh"

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
PYTHON="${PYTHON:-python3}"

BBOX=""
PROJECT="$REPO_ROOT/style/strassenraumkarte.qgz"
OUT="$REPO_ROOT/render/tiles"
ZMIN=15
ZMAX=20
METATILE=8
GUTTER=1
DPI=96
BACKGROUND="#ededed"
FORMAT="jpg"
WORKERS="${RENDER_WORKERS:-2}"
FONTS_DIR=""
NO_FONTS=0

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [$1] $2"
}

usage() {
  echo "Usage: $0 [--bbox xmin,ymin,xmax,ymax] [--project path] [--out dir] [--zmin N] [--zmax N] [--metatile N] [--gutter N] [--dpi N] [--background #rrggbb] [--format png|jpg] [--workers N] [--fonts-dir path] [--no-fonts]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bbox)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--bbox requires xmin,ymin,xmax,ymax"; usage; exit 1; }
      BBOX="$2"
      shift 2
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
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--format requires png or jpg"; usage; exit 1; }
      FORMAT="$2"
      shift 2
      ;;
    --workers)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--workers requires a number"; usage; exit 1; }
      WORKERS="$2"
      shift 2
      ;;
    --fonts-dir)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--fonts-dir requires a path"; usage; exit 1; }
      FONTS_DIR="$2"
      shift 2
      ;;
    --no-fonts)
      NO_FONTS=1
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

CALLER_PWD=$(pwd)
resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    echo "$path"
  elif [[ -e "$CALLER_PWD/$path" ]]; then
    echo "$CALLER_PWD/$path"
  else
    echo "$REPO_ROOT/$path"
  fi
}

PROJECT=$(resolve_path "$PROJECT")
OUT=$(resolve_path "$OUT")

if [[ ! -f "$PROJECT" ]]; then
  log ERROR "QGIS project not found: $PROJECT"
  exit 1
fi

if ! [[ "$ZMIN" =~ ^[0-9]+$ && "$ZMAX" =~ ^[0-9]+$ && "$ZMIN" -le "$ZMAX" ]]; then
  log ERROR "Invalid zoom range: zmin=$ZMIN zmax=$ZMAX"
  exit 1
fi

if ! [[ "$METATILE" =~ ^[0-9]+$ && "$METATILE" -ge 1 ]]; then
  log ERROR "Invalid --metatile: $METATILE"
  exit 1
fi

if ! [[ "$GUTTER" =~ ^[0-9]+$ ]]; then
  log ERROR "Invalid --gutter: $GUTTER"
  exit 1
fi

bg_hex="${BACKGROUND#\#}"
if ! [[ "$bg_hex" =~ ^[0-9A-Fa-f]{6}$ ]]; then
  log ERROR "Invalid --background (expected #rrggbb): $BACKGROUND"
  exit 1
fi
# bash 3.2 (macOS /bin/bash) has no ${var,,}; use tr
BACKGROUND="#$(printf '%s' "$bg_hex" | tr '[:upper:]' '[:lower:]')"

case "$FORMAT" in
  png|PNG|jpg|jpeg|JPG|JPEG) ;;
  *)
    log ERROR "Invalid --format: $FORMAT (use png or jpg)"
    exit 1
    ;;
esac

if [[ -n "$BBOX" ]]; then
  if ! [[ "$BBOX" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
    log ERROR "Invalid --bbox (expected xmin,ymin,xmax,ymax): $BBOX"
    exit 1
  fi
  IFS=',' read -r XMIN YMIN XMAX YMAX <<< "$BBOX"
  EXTENT="${XMIN},${XMAX},${YMIN},${YMAX} [EPSG:4326]"
  log INFO "Using bbox extent: $EXTENT"
else
  log INFO "No --bbox given; computing combined project layer extent..."
  EXTENT=$("$PYTHON" "$SCRIPT_DIR/project_extent.py" "$PROJECT") || {
    log ERROR "Failed to determine project extent."
    exit 1
  }
  log INFO "Using project extent: $EXTENT"
fi

mkdir -p "$OUT"

log INFO "Starting PyQGIS metatile renderer..."
log INFO "  python=$PYTHON"
log INFO "  project=$PROJECT"
log INFO "  out=$OUT"
log INFO "  zoom=${ZMIN}-${ZMAX} metatile=$METATILE gutter=$GUTTER dpi=$DPI format=$FORMAT workers=$WORKERS bg=$BACKGROUND"

EXTRA_ARGS=()
if [[ "$NO_FONTS" -eq 1 ]]; then
  EXTRA_ARGS+=(--no-fonts)
elif [[ -n "$FONTS_DIR" ]]; then
  EXTRA_ARGS+=(--fonts-dir "$(resolve_path "$FONTS_DIR")")
fi

DETAIL=$(python3 -c 'import json,sys; print(json.dumps({"project":sys.argv[1],"extent":sys.argv[2],"zmin":sys.argv[3],"zmax":sys.argv[4],"metatile":sys.argv[5],"gutter":sys.argv[6],"workers":sys.argv[7]}))' \
  "$PROJECT" "$EXTENT" "$ZMIN" "$ZMAX" "$METATILE" "$GUTTER" "$WORKERS")
# bash 3.2 + set -u: empty "${arr[@]}" is an unbound-variable error
RENDER_CMD=(
  "$PYTHON" "$SCRIPT_DIR/xyz_tiles.py"
  --project "$PROJECT"
  --extent "$EXTENT"
  --out "$OUT"
  --zmin "$ZMIN"
  --zmax "$ZMAX"
  --metatile "$METATILE"
  --gutter "$GUTTER"
  --dpi "$DPI"
  --background "$BACKGROUND"
  --format "$FORMAT"
  --workers "$WORKERS"
)
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  RENDER_CMD+=("${EXTRA_ARGS[@]}")
fi
perf_step "xyz_tiles_render" "render" --detail "$DETAIL" -- "${RENDER_CMD[@]}"
