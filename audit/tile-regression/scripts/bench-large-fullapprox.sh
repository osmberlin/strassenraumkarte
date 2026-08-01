#!/usr/bin/env bash
# Large-bbox full-style timing: Rust full-approx z15–z20.
# QGIS numbers in the report come from prior full-style audits (no highway_area).
# Optional: --also-qgis fills render/tiles for the same bbox/zooms (slow).
#
# Usage (repo root):
#   ./audit/tile-regression/scripts/bench-large-fullapprox.sh
#   ./audit/tile-regression/scripts/bench-large-fullapprox.sh --also-qgis
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HARNESS="$ROOT/audit/tile-regression"
BBOX="${BBOX:-13.3958,52.4243,13.4874,52.4849}"
ZMIN="${ZMIN:-15}"
ZMAX="${ZMAX:-20}"
ALSO_QGIS=0

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
    --also-qgis) ALSO_QGIS=1; shift ;;
    --help|-h)
      echo "Usage: $0 [--bbox …] [--zmin 15] [--zmax 20] [--also-qgis]"
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
RUN_DIR="${RUN_DIR:-$HARNESS/runs/bench-large-fullapprox-$TS}"
mkdir -p "$RUN_DIR"

RUST_BIN="$ROOT/rust/srk-render/target/release/srk-render"
if [[ ! -x "$RUST_BIN" ]]; then
  echo "[bench-large] building srk-render --release…"
  (cd "$ROOT/rust/srk-render" && cargo build --release)
fi

HOST_INFO="$(uname -srm 2>/dev/null || uname -a)"
CPU_COUNT="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo unknown)"
echo "[bench-large] run_dir=$RUN_DIR"
echo "[bench-large] bbox=$BBOX z${ZMIN}-${ZMAX} host=$HOST_INFO cpus=$CPU_COUNT"

RUST_OUT="$RUN_DIR/rust"
mkdir -p "$RUST_OUT"
echo "[bench-large] Rust full-approx (expect ~1e5 tiles at z15–20)…"
set +e
/usr/bin/time -p -o "$RUN_DIR/rust-time.txt" env \
  PGPASSFILE="$PGPASSFILE" PGPASSWORD="$PGPASSWORD" PGUSER="$PGUSER" \
  "$RUST_BIN" \
    --bbox "$BBOX" \
    --zmin "$ZMIN" \
    --zmax "$ZMAX" \
    --layers full-approx \
    --out "$RUST_OUT" \
    --format png \
    --quiet \
    --timing-json \
  >"$RUN_DIR/rust-stdout.log" 2>"$RUN_DIR/rust-stderr.log"
RUST_EXIT=$?
set -e
if [[ "$RUST_EXIT" -ne 0 ]]; then
  echo "[bench-large] Rust failed exit=$RUST_EXIT — see $RUN_DIR/rust-stderr.log" >&2
  exit "$RUST_EXIT"
fi

RUST_INTERNAL_MS="$(python3 -c "import json; print(json.load(open('$RUST_OUT/timing.json'))['wall_ms'])")"
RUST_EXTERNAL_S="$(awk '/^real /{print $2; exit}' "$RUN_DIR/rust-time.txt")"
RUST_PNG_COUNT="$(find "$RUST_OUT" -name '*.png' | wc -l | tr -d ' ')"

ln -sfn "$RUST_OUT" "$HARNESS/runs/latest-rust"
echo "[bench-large] rust tiles=$RUST_PNG_COUNT internal_ms=$RUST_INTERNAL_MS external_s=$RUST_EXTERNAL_S → latest-rust"

if [[ "$ALSO_QGIS" -eq 1 ]]; then
  echo "[bench-large] QGIS full style → render/tiles (metatile 8, jpg)…"
  (
    cd "$ROOT"
    # shellcheck disable=SC1091
    source render/qgis_env.sh
    export PGPASSFILE PGPASSWORD PGUSER DB_HOST DB_PORT DB_NAME
    /usr/bin/time -p -o "$RUN_DIR/qgis-time.txt" ./render/render_tiles.sh \
      --bbox "$BBOX" \
      --zmin "$ZMIN" \
      --zmax "$ZMAX" \
      --format jpg \
      --out "$ROOT/render/tiles" \
      >"$RUN_DIR/qgis-stdout.log" 2>"$RUN_DIR/qgis-stderr.log"
  )
fi

python3 - "$RUN_DIR/summary.json" "$BBOX" "$ZMIN" "$ZMAX" "$RUST_OUT/timing.json" \
  "$RUST_INTERNAL_MS" "$RUST_EXTERNAL_S" "$RUST_PNG_COUNT" "$HOST_INFO" "$CPU_COUNT" <<'PY'
import json, sys
from pathlib import Path
out, bbox, zmin, zmax, timing_path, rust_ms, rust_ext_s, pngs, host, cpus = sys.argv[1:11]
timing = json.loads(Path(timing_path).read_text()) if Path(timing_path).is_file() else {}
doc = {
    "bbox": bbox,
    "zmin": int(zmin),
    "zmax": int(zmax),
    "host": host,
    "cpus": cpus,
    "rust": {
        "preset": "full-approx",
        "tiles_written": int(pngs),
        "wall_ms_internal": int(rust_ms),
        "wall_s_external": float(rust_ext_s),
        "ms_per_tile": timing.get("ms_per_tile"),
        "by_zoom": timing.get("by_zoom"),
        "timing_json": timing,
    },
    "qgis_reference": {
        "note": "Full-style only — highway_area isolate omitted by design.",
        "large_bbox_audit": {
            "path": "audit/runs/20260801T115049Z_berlin-bbox-large/",
            "bbox": "13.3958,52.4243,13.4874,52.4849",
            "zmin": 15,
            "zmax": 18,
            "tiles_written": 1852,
            "wall_ms": 2845232,
            "incomplete": True,
            "note": "Killed mid-z18; z15–17 complete. ~47.4 min for 1852 tiles (~1.54 s/tile wall).",
        },
        "starter_bbox_full_style": {
            "path": "audit/tile-regression/runs/bench-20260801-153201/qgis-full-style-timing.json",
            "bbox": "13.4132,52.4715,13.4312,52.4821",
            "zmin": 15,
            "zmax": 18,
            "tiles": 278,
            "wall_ms": 92210,
            "ms_per_tile": 331.69,
            "metatile": 8,
        },
        "starter_bbox_historical": {
            "path": "audit/runs/20260801T113021Z_berlin-starter-clean",
            "tiles": 278,
            "wall_ms": 62302,
            "ms_per_tile": 224.1,
        },
    },
}
Path(out).write_text(json.dumps(doc, indent=2) + "\n")
print(f"wrote {out}")
PY

echo "[bench-large] done → $RUN_DIR"
