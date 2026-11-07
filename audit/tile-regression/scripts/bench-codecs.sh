#!/usr/bin/env bash
# Live-codec compare: PNG (lossless ref) vs WebP q90 vs JPG q90 — wall speed, size, quality.
# Live farm formats are webp/jpg; PNG is only the quality reference / harness codec.
#
# Usage (repo root):
#   ./audit/tile-regression/scripts/bench-codecs.sh
#   ZMIN=18 ZMAX=18 WORKERS=8 ./audit/tile-regression/scripts/bench-codecs.sh   # faster smoke
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export PATH="${HOME}/.cargo/bin:${PATH}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGPASSFILE="${PGPASSFILE:-/tmp/srk-pgpass/.pgpass}"
BBOX="${BBOX:-13.3958,52.4243,13.4874,52.4849}"
ZMIN="${ZMIN:-18}"
ZMAX="${ZMAX:-20}"
WORKERS="${WORKERS:-8}"
QUALITY="${QUALITY:-90}"
TS="$(date -u +%Y%m%d-%H%M%S)"
RUN="${RUN_DIR:-$ROOT/audit/tile-regression/runs/bench-codecs-$TS}"
BIN="$ROOT/rust/srk-render/target/release/srk-render"

mkdir -p /tmp/srk-pgpass
[[ -f "$PGPASSFILE" ]] || { printf 'localhost:5433:*:postgres:postgres\n' >"$PGPASSFILE"; chmod 600 "$PGPASSFILE"; }
[[ -x "$BIN" ]] || (cd "$ROOT/rust/srk-render" && cargo build --release)

mkdir -p "$RUN"
echo "[bench-codecs] run=$RUN bbox=$BBOX z$ZMIN-$ZMAX workers=$WORKERS q=$QUALITY"

for fmt in png webp jpg; do
  out="$RUN/$fmt"
  mkdir -p "$out"
  echo "[bench-codecs] render ${fmt}..."
  /usr/bin/time -p -o "$RUN/time-${fmt}.txt" "$BIN" \
    --bbox "$BBOX" --zmin "$ZMIN" --zmax "$ZMAX" \
    --layers full-approx --out "$out" --format "$fmt" --quality "$QUALITY" \
    --workers "$WORKERS" --quiet --timing-json --profile
done

python3 - "$RUN" "$QUALITY" <<'PY'
import json, subprocess, tempfile
from pathlib import Path

run = Path(__import__("sys").argv[1])
quality = float(__import__("sys").argv[2])

def du(root: Path, ext: str):
    n = total = 0
    for p in root.rglob(f"*.{ext}"):
        total += p.stat().st_size
        n += 1
    return n, total

summary = {"quality": quality, "formats": {}, "note": "PNG = lossless ref/harness; webp+jpg = live farm candidates at same --quality"}
for fmt in ("png", "webp", "jpg"):
    timing = json.loads((run / fmt / "timing.json").read_text())
    n, total = du(run / fmt, fmt)
    summary["formats"][fmt] = {
        "wall_ms": timing["wall_ms"],
        "wall_s": round(timing["wall_ms"] / 1000, 2),
        "ms_per_tile": timing["ms_per_tile"],
        "tiles_written": timing["tiles_written"],
        "stages": timing.get("stages"),
        "bytes_total": total,
        "mib_total": round(total / (1024 * 1024), 2),
        "bytes_avg": round(total / n) if n else 0,
        "tile_files": n,
        "vs_qgis_1568s": round(1568 / (timing["wall_ms"] / 1000), 2),
    }

# Quality sample tiles (must exist in this zoom range)
tiles = [
    "18/140844/86022",
    "18/140845/86022",
    "18/140846/86022",
    "18/140844/86023",
    "19/281688/172045",
    "19/281689/172045",
    "19/281690/172045",
    "20/563376/344090",
    "20/563377/344090",
    "20/563376/344091",
]

qdir = run / "quality"
qdir.mkdir(exist_ok=True)
quality_rows = []

def decode_to_png(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.suffix.lower() == ".webp":
        subprocess.check_call(["dwebp", str(src), "-o", str(dst)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif src.suffix.lower() in (".jpg", ".jpeg"):
        subprocess.check_call(["sips", "-s", "format", "png", str(src), "--out", str(dst)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        raise SystemExit(f"bad src {src}")

# Use bun pixelmatch from harness package
for t in tiles:
    z, x, y = t.split("/")
    png_path = run / "png" / z / x / f"{y}.png"
    if not png_path.is_file():
        quality_rows.append({"tile": t, "skip": "missing png"})
        continue
    row = {"tile": t, "png_bytes": png_path.stat().st_size}
    for fmt in ("webp", "jpg"):
        src = run / fmt / z / x / f"{y}.{fmt}"
        if not src.is_file():
            row[fmt] = {"skip": "missing"}
            continue
        tmp = qdir / f"{z}_{x}_{y}_{fmt}.png"
        try:
            decode_to_png(src, tmp)
            # pixelmatch via bun
            script = f"""
import {{ readFileSync }} from 'fs'
import {{ PNG }} from 'pngjs'
import pixelmatch from 'pixelmatch'
const ref = PNG.sync.read(readFileSync({json.dumps(str(png_path))}))
const cand = PNG.sync.read(readFileSync({json.dumps(str(tmp))}))
const {{ width, height }} = ref
const diff = new PNG({{ width, height }})
const m = pixelmatch(ref.data, cand.data, diff.data, width, height, {{ threshold: 0.1 }})
console.log(JSON.stringify({{ mism: m, total: width*height, ratio: m/(width*height) }}))
"""
            out = subprocess.check_output(
                ["bun", "-e", script],
                cwd=str(run.parents[1]),  # audit/tile-regression
                text=True,
            ).strip()
            stats = json.loads(out)
            row[fmt] = {
                "bytes": src.stat().st_size,
                "vs_png_size_pct": round(100 * src.stat().st_size / png_path.stat().st_size, 1),
                "pixelmatch": stats["ratio"],
                "pct": round(stats["ratio"] * 100, 3),
            }
        except Exception as e:
            row[fmt] = {"error": str(e)}
    quality_rows.append(row)

summary["quality_sample"] = quality_rows
# mean quality
for fmt in ("webp", "jpg"):
    vals = [r[fmt]["pct"] for r in quality_rows if isinstance(r.get(fmt), dict) and "pct" in r[fmt]]
    if vals:
        summary["formats"][fmt]["quality_mean_pixelmatch_pct"] = round(sum(vals) / len(vals), 3)
        summary["formats"][fmt]["quality_max_pixelmatch_pct"] = round(max(vals), 3)

(run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
print(f"wrote {run}/summary.json")
PY

echo "[bench-codecs] done → $RUN"
