#!/usr/bin/env bash
# psql against the Straßenraumkarte DB (Docker db service preferred).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ENV_FILE="$REPO_ROOT/docker/.env"
COMPOSE=(docker compose -f "$REPO_ROOT/docker/docker-compose.yml")
if [[ -f "$ENV_FILE" ]]; then
  COMPOSE+=(--env-file "$ENV_FILE")
fi

# Host tools path (rare on macOS without brew postgres client)
if command -v psql >/dev/null 2>&1 && [[ "${SQL_COMPARE_USE_DOCKER:-}" != "1" ]]; then
  # shellcheck source=../../data/db_config.sh
  source "$REPO_ROOT/data/db_config.sh"
  exec psql_base -d "$DB_NAME" "$@"
fi

exec "${COMPOSE[@]}" exec -T db \
  psql -U "${DB_USER:-postgres}" -d "${DB_NAME:-strassenraumkarte}" "$@"
