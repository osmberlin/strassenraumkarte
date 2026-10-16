#!/usr/bin/env bash
# Starter-bbox render timing: Rust srk-render vs QGIS highway_area isolate (+ optional full style).
#
# Usage (from repo root):
#   audit/tile-regression/scripts/bench-bbox.sh
#   audit/tile-regression/scripts/bench-bbox.sh --skip-full-style
#   BBOX=13.4132,52.4715,13.4312,52.4821 ZMIN=15 ZMAX=18 audit/tile-regression/scripts/bench-bbox.sh
#
# Writes:
#   audit/tile-regression/runs/bench-<ts>/tiles.txt
#   audit/tile-regression/runs/bench-<ts>/rust/  (+ timing.json)
#   audit/tile-regression/runs/bench-<ts>/qgis-highway_area/  (+ timing.json)
#   audit/tile-regression/runs/bench-<ts>/qgis-full-style/  (+ timing.json, unless --skip-full-style)
#   audit/tile-regression/runs/bench-<ts>/summary.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HARNESS="$ROOT/audit/tile-regression"
BBOX="${BBOX:-13.4132,52.4715,13.4312,52.4821}"
ZMIN="${ZMIN:-15}"
ZMAX="${ZMAX:-18}"
LAYERS="${LAYERS:-highway_area}"
SKIP_FULL_STYLE=0
RUN_FULL_STYLE=0

export PATH="${HOME}/.cargo/bin:${PATH}"
export PGPASSFILE="${PGPASSFILE:-/tmp/srk-pgpass/.pgpass}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGUSER="${PGUSER:-postgres}"
export DB_HOST="${DB_HOST:-localhost}"
export DB_PORT="${DB_PORT:-5433}"
export DB_NAME="${DB_NAME:-strassenraumkarte}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bbox) BBOX="$2"; shift 2 ;;
    --zmin) ZMIN="$2"; shift 2 ;;
    --zmax) ZMAX="$2"; shift 2 ;;
    --layers) LAYERS="$2"; shift 2 ;;
    --skip-full-style) SKIP_FULL_STYLE=1; shift ;;
    --help|-h)
      echo "Usage: $0 [--bbox xmin,ymin,xmax,ymax] [--zmin N] [--zmax N] [--layers highway_area] [--skip-full-style]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f /tmp/srk-pgpass/.pgpass ]]; then
  mkdir -p /tmp/srk-pgpass
  printf 'localhost:5433:*:postgres:postgres\n' > /tmp/srk-pgpass/.pgpass
  chmod 600 /tmp/srk-pgpass/.pgpass
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_DIR:-$HARNESS/runs/bench-$TS}"
mkdir -p "$RUN_DIR"

TILES_FILE="$RUN_DIR/tiles.txt"
TILES_CSV="$(
  python3 - "$BBOX" "$ZMIN" "$ZMAX" <<'PY'
import math
import sys

def clamp_lat(lat):
    return max(-85.05112878, min(85.05112878, lat))

def lon_to_tile_x(lon, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    return min(max(x, 0), n - 1)

def lat_to_tile_y(lat, z):
    lat = clamp_lat(lat)
    lat_rad = math.radians(lat)
    n = 2 ** z
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return min(max(y, 0), n - 1)

def tile_range_for_bbox(xmin, ymin, xmax, ymax, z):
    x0 = lon_to_tile_x(xmin, z)
    x1 = lon_to_tile_x(xmax, z)
    y0 = lat_to_tile_y(ymax, z)
    y1 = lat_to_tile_y(ymin, z)
    if x1 < x0:
        x0, x1 = x1, x0
    if y1 < y0:
        y0, y1 = y1, y0
    return x0, x1, y0, y1

bbox = [float(x) for x in sys.argv[1].split(",")]
zmin, zmax = int(sys.argv[2]), int(sys.argv[3])
xmin, ymin, xmax, ymax = bbox
tiles = []
for z in range(zmin, zmax + 1):
    x0, x1, y0, y1 = tile_range_for_bbox(xmin, ymin, xmax, ymax, z)
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            tiles.append(f"{z}/{x}/{y}")
print(",".join(tiles))
PY
)"
echo "$TILES_CSV" | tr ',' '\n' > "$TILES_FILE"
TILE_COUNT="$(wc -l < "$TILES_FILE" | tr -d ' ')"

HOST_INFO="$(uname -srm 2>/dev/null || uname -a)"
CPU_COUNT="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo unknown)"

echo "[bench-bbox] run_dir=$RUN_DIR"
echo "[bench-bbox] bbox=$BBOX z${ZMIN}-${ZMAX} tiles=$TILE_COUNT host=$HOST_INFO cpus=$CPU_COUNT"

RUST_BIN="$ROOT/rust/srk-render/target/release/srk-render"
if [[ ! -x "$RUST_BIN" ]]; then
  echo "[bench-bbox] building srk-render --release…"
  (cd "$ROOT/rust/srk-render" && cargo build --release)
fi

RUST_OUT="$RUN_DIR/rust"
mkdir -p "$RUST_OUT"
echo "[bench-bbox] 1/3 Rust highway_area…"
RUST_WALL_MS="$(
  /usr/bin/time -p env \
    PGPASSFILE="$PGPASSFILE" PGPASSWORD="$PGPASSWORD" PGUSER="$PGUSER" \
    "$RUST_BIN" \
      --bbox "$BBOX" \
      --zmin "$ZMIN" \
      --zmax "$ZMAX" \
      --layers "$LAYERS" \
      --out "$RUST_OUT" \
      --format png \
      --quiet \
    2>&1 | tee "$RUN_DIR/rust.log" | awk '/^real / {printf "%.0f\n", $2 * 1000}'
)"
RUST_PNG_COUNT="$(find "$RUST_OUT" -name '*.png' | wc -l | tr -d ' ')"
RUST_INTERNAL_MS="$(python3 -c "import json; print(json.load(open('$RUST_OUT/timing.json'))['wall_ms'])")"

QGIS_HA_OUT="$RUN_DIR/qgis-highway_area"
mkdir -p "$QGIS_HA_OUT"
echo "[bench-bbox] 2/3 QGIS highway_area isolate (metatile 1)…"
QGIS_HA_WALL_MS="$(
  /usr/bin/time -p \
    "$HARNESS/scripts/render-qgis-tile.sh" \
      --tiles "$TILES_CSV" \
      --layers "$LAYERS" \
      --out "$QGIS_HA_OUT" \
    2>&1 | tee "$RUN_DIR/qgis-highway_area.log" | awk '/^real / {printf "%.0f\n", $2 * 1000}'
)"
QGIS_HA_PNG_COUNT="$(find "$QGIS_HA_OUT" -name '*.png' | wc -l | tr -d ' ')"

python3 - "$QGIS_HA_OUT/timing.json" "$QGIS_HA_WALL_MS" "$TILE_COUNT" "$QGIS_HA_PNG_COUNT" "$BBOX" "$ZMIN" "$ZMAX" "$LAYERS" <<'PY'
import json, sys
out, wall_ms, tiles, written, bbox, zmin, zmax, layers = sys.argv[1:9]
wall_ms, tiles, written = int(wall_ms), int(tiles), int(written)
doc = {
    "engine": "qgis",
    "scope": f"highway_area isolate z{zmin}-{zmax}",
    "bbox": bbox,
    "zmin": int(zmin),
    "zmax": int(zmax),
    "tiles": tiles,
    "tiles_written": written,
    "wall_ms": wall_ms,
    "ms_per_tile": wall_ms / tiles if tiles else 0,
    "format": "png",
    "layers": [layers],
    "metatile": 1,
    "gutter": 1,
    "workers": 1,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(f"timing: engine=qgis isolate tiles={tiles} wall_ms={wall_ms} ms_per_tile={doc['ms_per_tile']:.2f}")
PY

QGIS_FULL_WALL_MS=""
QGIS_FULL_PNG_COUNT=""
if [[ "$SKIP_FULL_STYLE" -eq 0 ]]; then
  QGIS_FULL_OUT="$RUN_DIR/qgis-full-style"
  mkdir -p "$QGIS_FULL_OUT"
  echo "[bench-bbox] 3/3 QGIS full style (metatile 8)…"
  set +e
  QGIS_FULL_WALL_MS="$(
    /usr/bin/time -p \
      "$ROOT/render/render_tiles.sh" \
        --bbox "$BBOX" \
        --zmin "$ZMIN" \
        --zmax "$ZMAX" \
        --metatile 8 \
        --gutter 1 \
        --workers 1 \
        --format png \
        --out "$QGIS_FULL_OUT" \
      2>&1 | tee "$RUN_DIR/qgis-full-style.log" | awk '/^real / {printf "%.0f\n", $2 * 1000}'
  )"
  FULL_EXIT=$?
  set -e
  if [[ "$FULL_EXIT" -eq 0 && -n "$QGIS_FULL_WALL_MS" ]]; then
    QGIS_FULL_PNG_COUNT="$(find "$QGIS_FULL_OUT" -name '*.png' | wc -l | tr -d ' ')"
    python3 - "$RUN_DIR/qgis-full-style-timing.json" "$QGIS_FULL_WALL_MS" "$QGIS_FULL_PNG_COUNT" "$BBOX" "$ZMIN" "$ZMAX" <<'PY'
import json, sys
out, wall_ms, written, bbox, zmin, zmax = sys.argv[1:7]
wall_ms, written = int(wall_ms), int(written)
doc = {
    "engine": "qgis",
    "scope": f"full style z{zmin}-{zmax}",
    "bbox": bbox,
    "zmin": int(zmin),
    "zmax": int(zmax),
    "tiles_written": written,
    "tiles": written,
    "wall_ms": wall_ms,
    "ms_per_tile": wall_ms / written if written else 0,
    "format": "png",
    "metatile": 8,
    "gutter": 1,
    "workers": 1,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
    RUN_FULL_STYLE=1
  else
    echo "[bench-bbox] full-style run failed — cite historical only" >&2
  fi
else
  echo "[bench-bbox] 3/3 skipped (--skip-full-style)"
fi

python3 - "$RUN_DIR/summary.json" <<PY
import json, pathlib

run = pathlib.Path("$RUN_DIR")
rust = json.loads((run / "rust/timing.json").read_text())
qgis_ha = json.loads((run / "qgis-highway_area/timing.json").read_text())

summary = {
    "recorded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "host": "$HOST_INFO",
    "cpus": "$CPU_COUNT",
    "bbox": "$BBOX",
    "zmin": int("$ZMIN"),
    "zmax": int("$ZMAX"),
    "tile_count": int("$TILE_COUNT"),
    "rust": {
        "wall_ms_external": int("$RUST_WALL_MS"),
        "wall_ms_internal": int("$RUST_INTERNAL_MS"),
        "tiles_written": int("$RUST_PNG_COUNT"),
        "ms_per_tile": rust["ms_per_tile"],
        "engine": rust["engine"],
        "scope": rust["scope"],
    },
    "qgis_highway_area": {
        "wall_ms_external": int("$QGIS_HA_WALL_MS"),
        "tiles_written": int("$QGIS_HA_PNG_COUNT"),
        "ms_per_tile": qgis_ha["ms_per_tile"],
        "engine": qgis_ha["engine"],
        "scope": qgis_ha["scope"],
        "metatile": qgis_ha["metatile"],
    },
    "speedup_qgis_ha_vs_rust": round(int("$QGIS_HA_WALL_MS") / max(int("$RUST_INTERNAL_MS"), 1), 2),
}
full_path = run / "qgis-full-style-timing.json"
if full_path.is_file():
    summary["qgis_full_style_today"] = json.loads(full_path.read_text())
summary["historical_qgis_full_style"] = {
    "run": "audit/runs/20260801T113021Z_berlin-starter-clean",
    "wall_ms": 62302,
    "step_wall_ms": 67495,
    "tiles_written": 278,
    "zmin": 15,
    "zmax": 18,
    "metatile": 8,
    "note": "Full QGIS project; not comparable to highway_area-only Rust",
}
(run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
PY

echo "[bench-bbox] done → $RUN_DIR/summary.json"
echo "[bench-bbox] rust: ${RUST_INTERNAL_MS}ms internal / ${RUST_WALL_MS}ms wall (${RUST_PNG_COUNT} png)"
echo "[bench-bbox] qgis highway_area: ${QGIS_HA_WALL_MS}ms wall (${QGIS_HA_PNG_COUNT} png)"
if [[ "$RUN_FULL_STYLE" -eq 1 ]]; then
  echo "[bench-bbox] qgis full style: ${QGIS_FULL_WALL_MS}ms wall (${QGIS_FULL_PNG_COUNT} png)"
fi
