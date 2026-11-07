#!/usr/bin/env bash
#
# Run any pipeline command with performance auditing enabled.
# Creates audit/runs/<timestamp>_<label>/ with meta.json, steps.jsonl, console.log,
# then writes report.md + findings.json.
#
# Usage:
#   ./audit/run-with-audit.sh ./docker/run-berlin.sh
#   ./audit/run-with-audit.sh ./run.sh --data data/osm/berlin-latest.osm.pbf --bbox ...
#   PERF_AUDIT_LABEL=neukoelln ./audit/run-with-audit.sh ./docker/run-berlin.sh
#
# Safe to run in parallel with agent work — outputs go under gitignored audit/runs/.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 2
fi

LABEL="${PERF_AUDIT_LABEL:-pipeline}"
# Sanitize label for directory name
SAFE_LABEL=$(printf '%s' "$LABEL" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//')
TS=$(date -u +%Y%m%dT%H%M%SZ)
# Absolute path on the host; docker/run-berlin.sh remaps to /work/... inside the container.
RUN_DIR="$SCRIPT_DIR/runs/${TS}_${SAFE_LABEL}"
mkdir -p "$RUN_DIR"
export PERF_AUDIT_DIR="$RUN_DIR"
export PERF_AUDIT_LABEL="$LABEL"

cd "$REPO_ROOT"
perf_init

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Audit run: $PERF_AUDIT_DIR"
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Command: $*"

set +e
# Preserve exit code through tee
"$@" 2>&1 | tee "$PERF_AUDIT_DIR/console.log"
RC=${PIPESTATUS[0]}
set -e

if [[ "$RC" -eq 0 ]]; then
  perf_finish ok
else
  perf_finish fail
fi

python3 "$SCRIPT_DIR/write-report.py" "$PERF_AUDIT_DIR" || true

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Audit finished (exit $RC) → $PERF_AUDIT_DIR"
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Report: $PERF_AUDIT_DIR/report.md"
exit "$RC"
