#!/usr/bin/env bash
# Re-run Docker data prep for the SQL-compare bbox, snapshot, compare to reference.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BBOX="${BBOX:-13.3958,52.4243,13.4874,52.4849}"
LABEL="${LABEL:-after}"
CAND_DIR="$SCRIPT_DIR/candidates"
REF="${REF:-$SCRIPT_DIR/reference/baseline.json}"
OUT="$CAND_DIR/${LABEL}.json"
GROUP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --group) GROUP_ARGS+=(--group "$2"); shift 2 ;;
    --skip-prep) SKIP_PREP=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$CAND_DIR"
export BBOX
if [[ "${SKIP_PREP:-}" != "1" ]]; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Prep bbox=$BBOX"
  PERF_AUDIT_LABEL="sql-cand-${LABEL}" "$REPO_ROOT/audit/run-with-audit.sh" \
    "$REPO_ROOT/docker/run-berlin.sh"
fi

export SQL_COMPARE_USE_DOCKER=1
python3 "$SCRIPT_DIR/snapshot.py" "${GROUP_ARGS[@]}" --out "$OUT"
set +e
python3 "$SCRIPT_DIR/compare.py" "${GROUP_ARGS[@]}" "$REF" "$OUT"
rc=$?
set -e
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] candidate=$OUT compare_exit=$rc"
exit "$rc"
