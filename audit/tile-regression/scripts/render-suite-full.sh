#!/usr/bin/env bash
# Full-style QGIS vs Rust full-approx suite (z15–z20).
#
# Usage (from repo root):
#   ./audit/tile-regression/scripts/render-suite-full.sh
#
# Steps:
#   1) QGIS: FULL STYLE — no --layers filter → RUN/qgis/
#   2) Rust: --layers full-approx → RUN/rust/
#   3) bun compare-run.ts → RUN/compare/ (+ gallery)
#
# Vite compare UI:
#   RUST_TILES_ROOT=audit/tile-regression/runs/full-approx-<ts>/rust bun run dev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HARNESS="$ROOT/audit/tile-regression"
MANIFEST="${MANIFEST:-$HARNESS/manifest-full.json}"
SUITE="${SUITE:-full}"
TS="${TS:-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="${RUN_DIR:-$HARNESS/runs/full-approx-$TS}"
REF_DIR="${REF_DIR:-$RUN_DIR/qgis}"
CAND_DIR="${CAND_DIR:-$RUN_DIR/rust}"
COMPARE_OUT="${COMPARE_OUT:-$RUN_DIR/compare}"

export PATH="${HOME}/.cargo/bin:${PATH}"
export PGPASSFILE="${PGPASSFILE:-/tmp/srk-pgpass/.pgpass}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGUSER="${PGUSER:-postgres}"
export DB_HOST="${DB_HOST:-localhost}"
export DB_PORT="${DB_PORT:-5433}"
export DB_NAME="${DB_NAME:-strassenraumkarte}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite) SUITE="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; REF_DIR="$RUN_DIR/qgis"; CAND_DIR="$RUN_DIR/rust"; COMPARE_OUT="$RUN_DIR/compare"; shift 2 ;;
    --ref-dir) REF_DIR="$2"; shift 2 ;;
    --cand-dir) CAND_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--suite full] [--manifest PATH] [--run-dir DIR]"
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

TILES="$(
  bun -e "
    const m = await Bun.file(process.argv[1]).json()
    const suite = process.argv[2]
    const ids = m.tiles.filter((t) => t.suite === suite).map((t) => t.id)
    if (!ids.length) throw new Error('no tiles for suite=' + suite)
    console.log(ids.join(','))
  " "$MANIFEST" "$SUITE"
)"

echo "[render-suite-full] suite=$SUITE"
echo "[render-suite-full] tiles=$TILES"
echo "[render-suite-full] run → $RUN_DIR"
echo "[render-suite-full] QGIS full-style → $REF_DIR"
echo "[render-suite-full] Rust full-approx → $CAND_DIR"

mkdir -p "$REF_DIR" "$CAND_DIR" "$COMPARE_OUT"

echo "[render-suite-full] 1/3 QGIS reference (FULL STYLE, no --layers)…"
"$HARNESS/scripts/render-qgis-tile.sh" \
  --tiles "$TILES" \
  --out "$REF_DIR"

echo "[render-suite-full] 2/3 Rust candidate (full-approx)…"
RUST_BIN="$ROOT/rust/srk-render/target/release/srk-render"
if [[ ! -x "$RUST_BIN" ]]; then
  echo "[render-suite-full] building srk-render --release…"
  (cd "$ROOT/rust/srk-render" && cargo build --release)
fi
"$RUST_BIN" \
  --tiles "$TILES" \
  --layers full-approx \
  --out "$CAND_DIR" \
  --format png \
  --timing-json

echo "[render-suite-full] 3/3 compare-run…"
cd "$HARNESS"
bun run scripts/compare-run.ts \
  --manifest "$MANIFEST" \
  --suite "$SUITE" \
  --ref-dir "$REF_DIR" \
  --cand-dir "$CAND_DIR" \
  --out "$COMPARE_OUT" \
  --layers full-approx

# Point a convenience symlink at this run's rust tiles for Vite.
ln -sfn "$CAND_DIR" "$HARNESS/runs/latest-rust"
echo "[render-suite-full] rust tiles: $CAND_DIR"
echo "[render-suite-full] gallery:    $COMPARE_OUT/index.html"
echo "[render-suite-full] Vite:       RUST_TILES_ROOT=$CAND_DIR bun run --cwd vector dev"
echo "[render-suite-full] done"
