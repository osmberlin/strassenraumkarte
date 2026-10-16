#!/usr/bin/env bash
#
# Freeze a SQL fingerprint reference after a full data prep (no render).
#
# Default bbox = large Neukölln-ish area from the performance audit
# (SQL ~1–2 min; the multi-hour cost was QGIS render, not SQL).
#
# Usage:
#   ./audit/sql-compare/run-reference.sh
#   BBOX=13.4132,52.4715,13.4312,52.4821 ./audit/sql-compare/run-reference.sh
#   LABEL=myref ./audit/sql-compare/run-reference.sh
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# Large enough for hot scripts to show signal; prep stays ~1–2 minutes.
BBOX="${BBOX:-13.3958,52.4243,13.4874,52.4849}"
LABEL="${LABEL:-baseline}"
REF_DIR="$SCRIPT_DIR/reference"
OUT_JSON="$REF_DIR/${LABEL}.json"
META_JSON="$REF_DIR/${LABEL}.meta.json"

mkdir -p "$REF_DIR"

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] SQL compare reference bbox=$BBOX label=$LABEL"

export BBOX
export PERF_AUDIT_LABEL="sql-ref-${LABEL}"
# Data prep only — render is not needed for SQL fingerprints.
"$REPO_ROOT/audit/run-with-audit.sh" "$REPO_ROOT/docker/run-berlin.sh"

export SQL_COMPARE_USE_DOCKER=1
python3 "$SCRIPT_DIR/snapshot.py" --out "$OUT_JSON"

python3 - <<PY
import json, os, subprocess, time
from pathlib import Path
meta = {
  "label": os.environ.get("LABEL", "$LABEL"),
  "bbox": "$BBOX",
  "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
  "git": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd="$REPO_ROOT", text=True).strip(),
  "snapshot": str(Path("$OUT_JSON").relative_to("$REPO_ROOT")),
}
Path("$META_JSON").write_text(json.dumps(meta, indent=2) + "\n")
print("Wrote", "$META_JSON")
PY

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Reference snapshot → $OUT_JSON"
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Compare later with:"
echo "  ./audit/sql-compare/snapshot.py --out audit/sql-compare/candidates/after.json"
echo "  ./audit/sql-compare/compare.py $OUT_JSON audit/sql-compare/candidates/after.json"
