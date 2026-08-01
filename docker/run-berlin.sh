#!/usr/bin/env bash
#
# Run Straßenraumkarte data preparation for Berlin inside Docker.
#
# Uses BERLIN_PBF (symlink) + BBOX from docker/.env (see .env.example).
# Extra arguments are forwarded to ./run.sh after the defaults.
#
# Examples:
#   ./docker/run-berlin.sh
#   BBOX=13.4,52.47,13.45,52.48 ./docker/run-berlin.sh
#   ./docker/run-berlin.sh --skip-processing
#   PERF_AUDIT_LABEL=berlin ./audit/run-with-audit.sh ./docker/run-berlin.sh
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE=(docker compose -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [$1] $2"
}

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  log INFO "Created $ENV_FILE from .env.example"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BBOX="${BBOX:-13.4132,52.4715,13.4312,52.4821}"
DATA="${DATA:-data/osm/berlin-latest.osm.pbf}"

if [[ -z "${BERLIN_PBF_MOUNT:-}" ]] || [[ ! -L "$REPO_ROOT/data/osm/berlin-latest.osm.pbf" && ! -f "$REPO_ROOT/data/osm/berlin-latest.osm.pbf" ]]; then
  log INFO "Ensuring Berlin PBF symlink / mount..."
  "$SCRIPT_DIR/link-berlin-pbf.sh"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

log INFO "Starting database (if needed)..."
"${COMPOSE[@]}" up -d db

# Map host PERF_AUDIT_DIR into the container (/work is the repo mount).
if [[ -n "${PERF_AUDIT_DIR:-}" ]]; then
  case "$PERF_AUDIT_DIR" in
    "$REPO_ROOT"/*)
      export PERF_AUDIT_DIR="/work/${PERF_AUDIT_DIR#"$REPO_ROOT"/}"
      ;;
    /*)
      # Already absolute but not under this repo — leave as-is (may fail in container).
      ;;
    *)
      export PERF_AUDIT_DIR="/work/$PERF_AUDIT_DIR"
      ;;
  esac
  log INFO "Container PERF_AUDIT_DIR=$PERF_AUDIT_DIR"
fi

log INFO "Running data prep: data=$DATA bbox=$BBOX"
# Defaults: setup DB, refresh schema, import+process, skip host QGIS render.
# Override bbox with BBOX=...; append extra ./run.sh flags via "$@".
# Pass BBOX into the container env for audit meta.json.
exec "${COMPOSE[@]}" run --rm \
  -e "PERF_AUDIT_DIR=${PERF_AUDIT_DIR:-}" \
  -e "PERF_AUDIT_LABEL=${PERF_AUDIT_LABEL:-}" \
  -e "BBOX=$BBOX" \
  tools \
  ./run.sh \
  --setup-db \
  --refresh \
  --skip-render \
  --data "$DATA" \
  --bbox "$BBOX" \
  "$@"
