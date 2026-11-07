#!/usr/bin/env bash
# Render starter-bbox reference tiles (1 worker) into gitignored reference/.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$DIR/../.." && pwd)
BBOX="${BBOX:-13.4132,52.4715,13.4312,52.4821}"
ZMIN="${ZMIN:-15}"
ZMAX="${ZMAX:-18}"
OUT="$DIR/reference/starter-z${ZMIN}-${ZMAX}"

# shellcheck source=../../render/qgis_env.sh
source "$REPO_ROOT/render/qgis_env.sh"
export PGPASSFILE="${PGPASSFILE:-/tmp/srk-pgpass/.pgpass}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGUSER="${PGUSER:-postgres}"

mkdir -p "$OUT"
rm -rf "$OUT"/*
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Freezing reference → $OUT"
"$REPO_ROOT/render/render_tiles.sh" \
  --bbox "$BBOX" \
  --out "$OUT" \
  --zmin "$ZMIN" \
  --zmax "$ZMAX" \
  --jobs 1

python3 - <<PY
import json, time
from pathlib import Path
out = Path("$OUT")
n = sum(1 for _ in out.rglob("*.jpg")) + sum(1 for _ in out.rglob("*.png"))
meta = {
  "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
  "bbox": "$BBOX",
  "zmin": int("$ZMIN"),
  "zmax": int("$ZMAX"),
  "workers": 1,
  "tiles": n,
  "path": str(out),
}
(out.parent / "starter-z${ZMIN}-${ZMAX}.meta.json").write_text(json.dumps(meta, indent=2)+"\n")
print(json.dumps(meta, indent=2))
PY
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Reference ready ($OUT)"
