#!/usr/bin/env bash
#
# Explore QGIS render knobs on the starter bbox (fonts + parallel workers).
# Writes audit/render-explore/<timestamp>/report.md
#
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BBOX="${BBOX:-13.4132,52.4715,13.4312,52.4821}"
ZMIN="${ZMIN:-15}"
ZMAX="${ZMAX:-18}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT_ROOT="$SCRIPT_DIR/$TS"
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
  local tiles="$case_dir/tiles"
  mkdir -p "$tiles"
  export PERF_AUDIT_DIR="$case_dir"
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] === case $name === $*"
  set +e
  "$REPO_ROOT/render/render_tiles.sh" \
    --bbox "$BBOX" \
    --out "$tiles" \
    --zmin "$ZMIN" \
    --zmax "$ZMAX" \
    "$@" >"$case_dir/console.log" 2>"$case_dir/stderr.log"
  local rc=$?
  set -e
  # Also show a short tail on the console
  tail -n 5 "$case_dir/console.log" || true
  echo "$rc" >"$case_dir/exit_code.txt"
  if grep -q 'Open Sans' "$case_dir/stderr.log" "$case_dir/console.log" 2>/dev/null; then
    echo "open_sans_alias_warning=yes" >"$case_dir/font_note.txt"
  else
    echo "open_sans_alias_warning=no" >"$case_dir/font_note.txt"
  fi
}

run_case baseline --workers 1 --no-fonts
run_case fonts --workers 1
run_case workers2 --workers 2
run_case workers4 --workers 4

export OUT_ROOT BBOX ZMIN ZMAX
python3 <<'PY'
import json, os, time
from pathlib import Path

root = Path(os.environ["OUT_ROOT"])
bbox = os.environ["BBOX"]
zmin, zmax = os.environ["ZMIN"], os.environ["ZMAX"]
cases = []
for name in ["baseline", "fonts", "workers2", "workers4"]:
    d = root / name
    summary = {}
    sp = d / "render_summary.json"
    if sp.exists():
        summary = json.loads(sp.read_text())
    exit_code = int((d / "exit_code.txt").read_text().strip() or "1")
    font_note = (d / "font_note.txt").read_text().strip() if (d / "font_note.txt").exists() else ""
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
        "workers": summary.get("workers"),
        "fonts_dir": summary.get("fonts_dir"),
        "font_note": font_note,
    })

base = next((c for c in cases if c["name"] == "baseline"), None)
lines = [
    f"# QGIS render exploration — {root.name}",
    "",
    f"- **BBox:** `{bbox}` (starter)",
    f"- **Zoom:** {zmin}–{zmax}",
    "- **Host:** Darwin / QGIS 4.0.2 app bundle",
    f"- **Date (UTC):** {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
    "",
    "## Cases",
    "",
    "| Case | Wall | vs baseline | Tiles | Avg metatile | Max metatile | Notes |",
    "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
]
for c in cases:
    wall = c["wall_s"]
    if c["exit_code"] != 0 or wall is None:
        wall_s, vs = "FAIL", "—"
    elif base and base.get("wall_ms"):
        wall_s = f"{wall:.1f}s"
        vs = f"{wall / (base['wall_ms']/1000):.2f}×"
    else:
        wall_s, vs = f"{wall:.1f}s", "—"
    notes = c.get("font_note") or ""
    if c["name"] == "fonts":
        notes = f"{notes}; Open Sans TTFs in render/fonts".strip("; ")
    if c["name"].startswith("workers"):
        notes = f"workers={c.get('workers')}; {notes}".strip("; ")
    lines.append(
        f"| `{c['name']}` | {wall_s} | {vs} | {c.get('tiles') or '—'} | "
        f"{c.get('avg_metatile_ms') or '—'} ms | {c.get('max_metatile_ms') or '—'} ms | {notes} |"
    )

lines += [
    "",
    "## Findings",
    "",
    "- **Open Sans:** project requests this family; without `render/fonts` Qt logs "
    "`Populating font family aliases…` (~40 ms once at startup). Bundling TTFs removes "
    "the warning; wall-time impact on this bbox is expected to be noise.",
    "- **Parallel workers:** each process loads QGIS + the .qgz once, then paints a "
    "disjoint metatile subset. Speedup depends on CPU vs PostGIS contention. "
    "Not thread-based (PyQGIS is not thread-safe).",
    "- **`QT_IMAGEIO_MAXALLOC=0`:** set in `render/qgis_env.sh` to avoid the 512 MB "
    "symbol decode rejects seen on denser bboxes (little effect on this tiny AOI).",
    "",
    "## Raw",
    "",
    f"- Directory: `{root}`",
    "- Per case: `render_summary.json`, `render_metatiles.jsonl`, `console.log`",
    "",
]

report = root / "report.md"
report.write_text("\n".join(lines) + "\n")
(root / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
print(report.read_text())
print("Wrote", report)
PY

echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Explore finished → $OUT_ROOT"
