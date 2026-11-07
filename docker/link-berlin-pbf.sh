#!/usr/bin/env bash
#
# Create/update data/osm/berlin-latest.osm.pbf as a symlink to BERLIN_PBF_SOURCE,
# and set BERLIN_PBF_MOUNT (absolute path) in docker/.env for the tools container.
#
# Configure the source in docker/.env (see docker/.env.example), or export
# BERLIN_PBF_SOURCE before running. Re-run after changing the source path or
# replacing the underlying PBF file.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
LINK_PATH="$REPO_ROOT/data/osm/berlin-latest.osm.pbf"

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [$1] $2"
}

upsert_env() {
  local key="$1"
  local value="$2"
  local file="$3"
  if [[ -f "$file" ]] && grep -q "^${key}=" "$file"; then
    # Portable in-place replace (macOS / GNU)
    local tmp
    tmp=$(mktemp)
    awk -v k="$key" -v v="$value" 'BEGIN{p=0} $0 ~ "^"k"=" {print k"="v; p=1; next} {print} END{if(!p) print k"="v}' "$file" >"$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

# Ensure docker/.env exists so we can store BERLIN_PBF_MOUNT for Compose.
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    log INFO "Created $ENV_FILE from .env.example"
  else
    touch "$ENV_FILE"
  fi
fi

# Load docker/.env (does not override already-exported vars).
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

DEFAULT_SOURCE="$REPO_ROOT/../osm-processing-pipeline-comparison/data/raw/berlin-latest.osm.pbf"
SOURCE="${BERLIN_PBF_SOURCE:-$DEFAULT_SOURCE}"

# Resolve relative paths against the repository root.
if [[ "$SOURCE" != /* ]]; then
  SOURCE="$REPO_ROOT/$SOURCE"
fi

if [[ ! -e "$SOURCE" ]]; then
  log ERROR "BERLIN_PBF_SOURCE does not exist: $SOURCE"
  log ERROR "Set BERLIN_PBF_SOURCE in docker/.env (see docker/.env.example) or export it,"
  log ERROR "then re-run: ./docker/link-berlin-pbf.sh"
  exit 1
fi

SOURCE=$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")

mkdir -p "$(dirname "$LINK_PATH")"

if [[ -e "$LINK_PATH" || -L "$LINK_PATH" ]]; then
  if [[ -L "$LINK_PATH" ]]; then
    log INFO "Replacing existing symlink: $LINK_PATH"
  else
    log ERROR "Refusing to overwrite non-symlink file: $LINK_PATH"
    log ERROR "Move or remove it, then re-run."
    exit 1
  fi
fi

ln -sfn "$SOURCE" "$LINK_PATH"
upsert_env "BERLIN_PBF_MOUNT" "$SOURCE" "$ENV_FILE"

log INFO "Linked $LINK_PATH -> $SOURCE"
log INFO "Set BERLIN_PBF_MOUNT=$SOURCE in $ENV_FILE (Docker bind mount)"
log INFO "To retarget: edit BERLIN_PBF_SOURCE in docker/.env (or export it), then re-run this script."
log INFO "To refresh data: replace/update the source PBF, then re-run the pipeline with --refresh."
