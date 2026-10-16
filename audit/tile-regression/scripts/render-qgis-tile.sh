#!/usr/bin/env bash
# Render one (or more) XYZ PNG tiles with PyQGIS for regression compares.
#
# Usage:
#   audit/tile-regression/scripts/render-qgis-tile.sh \
#     --tiles 17/70422/43008 \
#     --layers highway_area \
#     --out /tmp/srk-one-tile-ref
#
# Extra args are forwarded to render/xyz_tiles.py.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

# shellcheck source=/dev/null
source "$ROOT/render/qgis_env.sh"

export PGPASSFILE="${PGPASSFILE:-/tmp/srk-pgpass/.pgpass}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGUSER="${PGUSER:-postgres}"
export DB_HOST="${DB_HOST:-localhost}"
export DB_PORT="${DB_PORT:-5433}"
export DB_NAME="${DB_NAME:-strassenraumkarte}"

PYTHON="${PYTHON:-python3}"
PROJECT="${PROJECT:-style/strassenraumkarte.qgz}"

exec "$PYTHON" "$ROOT/render/xyz_tiles.py" \
  --project "$PROJECT" \
  --format png \
  --metatile 1 \
  --gutter 1 \
  --workers 1 \
  "$@"
