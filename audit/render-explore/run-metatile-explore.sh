#!/usr/bin/env bash
#
# Metatile / gutter knobs on the starter bbox (z15–18).
# Reference case: metatile=8 gutter=1 (current defaults).
# Writes audit/render-explore/<timestamp>_metatile/report.md
#
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BBOX="${BBOX:-13.4132,52.4715,13.4312,52.4821}"
ZMIN="${ZMIN:-15}"
ZMAX="${ZMAX:-18}"
WORKERS="${WORKERS:-2}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT_ROOT="$SCRIPT_DIR/${TS}_metatile"
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
    --workers "$WORKERS" \
    "$@" >"$case_dir/console.log" 2>"$case_dir/stderr.log"
  local rc=$?
  set -e
  echo "$rc" >"$case_dir/exit_code.txt"
  tail -n 3 "$case_dir/console.log" || true
}

# name → extra args
run_case mt4 --metatile 4 --gutter 1
run_case mt8 --metatile 8 --gutter 1
run_case mt16 --metatile 16 --gutter 1
run_case gutter0 --metatile 8 --gutter 0

export OUT_ROOT BBOX ZMIN ZMAX WORKERS REPO_ROOT
python3 <<'PY'
import json, os, subprocess, time
from pathlib import Path

root = Path(os.environ["OUT_ROOT"])
bbox = os.environ["BBOX"]
zmin, zmax = os.environ["ZMIN"], os.environ["ZMAX"]
workers = os.environ["WORKERS"]
repo = Path(os.environ["REPO_ROOT"])
compare = repo / "audit/tile-compare/.venv/bin/python"
compare_script = repo / "audit/tile-compare/compare-tiles.py"
ref_tiles = root / "mt8" / "tiles"

case_names = ["mt4", "mt8", "mt16", "gutter0"]
cases = []
for name in case_names:
    d = root / name
    summary = json.loads((d / "render_summary.json").read_text()) if (d / "render_summary.json").exists() else {}
    exit_code = int((d / "exit_code.txt").read_text().strip() or "1")
    wall = summary.get("wall_ms")
    ssim = None
    ssim_pass = None
    if name != "mt8" and exit_code == 0 and compare.exists() and ref_tiles.exists():
        out = root / "ssim" / name
        out.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(
            [str(compare), str(compare_script), str(ref_tiles), str(d / "tiles"), "--out", str(out)],
            capture_output=True,
            text=True,
        )
        ssim_pass = r.returncode == 0
        sj = out / "summary.json"
        if sj.exists():
            ssim = json.loads(sj.read_text())
    cases.append({
        "name": name,
        "exit_code": exit_code,
        "wall_ms": wall,
        "wall_s": round(wall / 1000, 1) if wall else None,
        "tiles": summary.get("tiles_written"),
        "metatiles": summary.get("metatile_count"),
        "avg_metatile_ms": summary.get("duration_ms_avg"),
        "max_metatile_ms": summary.get("duration_ms_max"),
        "metatile": summary.get("metatile") or {"mt4": 4, "mt8": 8, "mt16": 16, "gutter0": 8}.get(name),
        "gutter": 0 if name == "gutter0" else 1,
        "ssim_pass": ssim_pass,
        "ssim_mean": (ssim or {}).get("mean_ssim"),
        "ssim_min": (ssim or {}).get("min_ssim"),
    })

base = next((c for c in cases if c["name"] == "mt8"), None)
lines = [
    f"# Metatile / gutter exploration — {root.name}",
    "",
    f"- **BBox:** `{bbox}` (starter)",
    f"- **Zoom:** {zmin}–{zmax}",
    f"- **Workers:** {workers}",
    f"- **Reference for SSIM:** `mt8` (metatile=8, gutter=1)",
    f"- **Date (UTC):** {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
    "",
    "## Cases",
    "",
    "| Case | MT | Gutter | Wall | vs mt8 | Metatiles | Avg MT | Max MT | SSIM vs mt8 |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
]
for c in cases:
    if c["exit_code"] != 0 or not c["wall_s"]:
        lines.append(f"| `{c['name']}` | {c['metatile']} | {c['gutter']} | FAIL | — | — | — | — | — |")
        continue
    vs = f"{c['wall_s'] / (base['wall_ms']/1000):.2f}×" if base and base.get("wall_ms") and c["name"] != "mt8" else ("1.00×" if c["name"] == "mt8" else "—")
    if c["name"] == "mt8":
        ssim_cell = "ref"
    elif c["ssim_pass"] is None:
        ssim_cell = "n/a"
    elif c["ssim_pass"]:
        ssim_cell = f"PASS (mean {c['ssim_mean']:.4f})" if c.get("ssim_mean") is not None else "PASS"
    else:
        ssim_cell = f"FAIL (min {c.get('ssim_min')})"
    lines.append(
        f"| `{c['name']}` | {c['metatile']} | {c['gutter']} | {c['wall_s']:.1f}s | {vs} | "
        f"{c['metatiles']} | {c['avg_metatile_ms']} ms | {c['max_metatile_ms']} ms | {ssim_cell} |"
    )

lines += [
    "",
    "## Findings",
    "",
    "- Smaller metatiles → more QGIS paint jobs (startup/overhead) but lower peak RAM / max MT.",
    "- Larger metatiles → fewer jobs; may help or hurt depending on effects/memory.",
    "- Gutter 0 saves paint of border tiles but can clip labels/symbols — only keep if SSIM/visual OK.",
    "",
    f"- Raw: `{root}`",
    "",
]
(root / "report.md").write_text("\n".join(lines) + "\n")
(root / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
print((root / "report.md").read_text())
PY
echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] Done → $OUT_ROOT"
