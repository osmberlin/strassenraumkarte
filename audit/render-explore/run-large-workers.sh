#!/usr/bin/env bash
#
# Worker scaling on the large Berlin bbox.
# Defaults: z16 only (fast signal). Override with ZMIN/ZMAX/CASES.
# Writes audit/render-explore/<timestamp>_large-workers/report.md
#
# Examples:
#   ./audit/render-explore/run-large-workers.sh
#   ZMIN=15 ZMAX=17 CASES="workers1 workers2 workers4" ./audit/render-explore/run-large-workers.sh
#
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BBOX="${BBOX:-13.3958,52.4243,13.4874,52.4849}"
ZMIN="${ZMIN:-16}"
ZMAX="${ZMAX:-16}"
# Space-separated case names: workers1 workers2 workers4
CASES="${CASES:-workers1 workers2 workers4}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT_ROOT="$SCRIPT_DIR/${TS}_large-workers"
mkdir -p "$OUT_ROOT"

# shellcheck source=../../render/qgis_env.sh
source "$REPO_ROOT/render/qgis_env.sh"

export PGPASSFILE="${PGPASSFILE:-/tmp/srk-pgpass/.pgpass}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGUSER="${PGUSER:-postgres}"
export DB_HOST="${DB_HOST:-localhost}"
export DB_PORT="${DB_PORT:-5433}"

run_case() {
  local name="$1"
  shift
  local case_dir="$OUT_ROOT/$name"
  mkdir -p "$case_dir/tiles"
  export PERF_AUDIT_DIR="$case_dir"
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] === case $name === $*"
  set +e
  "$REPO_ROOT/render/render_tiles.sh" \
    --bbox "$BBOX" \
    --out "$case_dir/tiles" \
    --zmin "$ZMIN" \
    --zmax "$ZMAX" \
    "$@" >"$case_dir/console.log" 2>"$case_dir/stderr.log"
  local rc=$?
  set -e
  echo "$rc" >"$case_dir/exit_code.txt"
  tail -n 3 "$case_dir/console.log" || true
}

for case_name in $CASES; do
  n=${case_name#workers}
  run_case "$case_name" --workers "$n"
done

export OUT_ROOT BBOX ZMIN ZMAX CASES
python3 <<'PY'
import json, os, time
from pathlib import Path

root = Path(os.environ["OUT_ROOT"])
bbox = os.environ["BBOX"]
zmin, zmax = os.environ["ZMIN"], os.environ["ZMAX"]
case_names = os.environ["CASES"].split()
cases = []
for name in case_names:
    d = root / name
    summary = json.loads((d / "render_summary.json").read_text()) if (d / "render_summary.json").exists() else {}
    exit_code = int((d / "exit_code.txt").read_text().strip() or "1")
    wall = summary.get("wall_ms")
    cases.append({
        "name": name,
        "exit_code": exit_code,
        "wall_ms": wall,
        "wall_s": round(wall / 1000, 1) if wall else None,
        "tiles": summary.get("tiles_written"),
        "metatiles": summary.get("metatile_count"),
        "avg_metatile_ms": summary.get("duration_ms_avg"),
        "max_metatile_ms": summary.get("duration_ms_max"),
        "workers": summary.get("workers") or int(name.replace("workers", "")),
        "cpu_ms_sum": summary.get("duration_ms_sum"),
    })

base = next((c for c in cases if c["name"] == "workers1"), None)
lines = [
    f"# Large-bbox worker scaling — {root.name}",
    "",
    f"- **BBox:** `{bbox}`",
    f"- **Zoom:** {zmin}–{zmax} (z18 omitted — multi-hour alone in prior audit)",
    f"- **Cases:** {', '.join(case_names)}",
    f"- **Date (UTC):** {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
    "",
    "## Cases",
    "",
    "| Case | Workers | Wall | vs 1× | Tiles | Metatiles | Avg MT | Max MT | CPU-sum |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
]
for c in cases:
    if c["exit_code"] != 0 or not c["wall_s"]:
        lines.append(f"| `{c['name']}` | {c['workers']} | FAIL | — | — | — | — | — | — |")
        continue
    vs = f"{c['wall_s'] / (base['wall_ms']/1000):.2f}×" if base and base.get("wall_ms") else "—"
    cpu = f"{c['cpu_ms_sum']/1000:.0f}s" if c.get("cpu_ms_sum") else "—"
    lines.append(
        f"| `{c['name']}` | {c['workers']} | {c['wall_s']:.1f}s | {vs} | {c['tiles']} | "
        f"{c['metatiles']} | {c['avg_metatile_ms']} ms | {c['max_metatile_ms']} ms | {cpu} |"
    )

lines += [
    "",
    "## Findings",
    "",
    "- Wall time should drop with workers until PostGIS or disk saturates.",
    "- CPU-sum (sum of metatile durations) ≈ total paint work; wall ≪ CPU-sum means good overlap.",
    "- If 4× ≈ 2× wall, prefer `--workers 2` as default for this hardware/bbox class.",
    "",
    f"- Raw: `{root}`",
    "",
]
(root / "report.md").write_text("\n".join(lines) + "\n")
(root / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
print((root / "report.md").read_text())
PY
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Done → $OUT_ROOT"
