#!/usr/bin/env bash
# Render + compare the smoke suite (highway_area isolate).
#
# Usage (from repo root or anywhere):
#   audit/tile-regression/scripts/render-suite.sh
#   audit/tile-regression/scripts/render-suite.sh --suite smoke
#   REF_DIR=/tmp/a CAND_DIR=/tmp/b audit/tile-regression/scripts/render-suite.sh
#
# Steps:
#   1) QGIS: one call with all --tiles + --layers highway_area → REF_DIR
#   2) Rust: one call with all tiles → CAND_DIR
#   3) bun compare-run.ts → runs/<ts>-smoke/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HARNESS="$ROOT/audit/tile-regression"
MANIFEST="${MANIFEST:-$HARNESS/manifest.json}"
SUITE="${SUITE:-smoke}"
LAYERS="${LAYERS:-highway_area}"
REF_DIR="${REF_DIR:-/tmp/srk-smoke-ref}"
CAND_DIR="${CAND_DIR:-/tmp/srk-smoke-cand}"

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
    --layers) LAYERS="$2"; shift 2 ;;
    --ref-dir) REF_DIR="$2"; shift 2 ;;
    --cand-dir) CAND_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--suite smoke] [--manifest PATH] [--layers highway_area] [--ref-dir DIR] [--cand-dir DIR]"
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

echo "[render-suite] suite=$SUITE layers=$LAYERS"
echo "[render-suite] tiles=$TILES"
echo "[render-suite] ref → $REF_DIR"
echo "[render-suite] cand → $CAND_DIR"

mkdir -p "$REF_DIR" "$CAND_DIR"

echo "[render-suite] 1/3 QGIS reference…"
"$HARNESS/scripts/render-qgis-tile.sh" \
  --tiles "$TILES" \
  --layers "$LAYERS" \
  --out "$REF_DIR"

echo "[render-suite] 2/3 Rust candidate…"
RUST_BIN="$ROOT/rust/srk-render/target/release/srk-render"
if [[ ! -x "$RUST_BIN" ]]; then
  echo "[render-suite] building srk-render --release…"
  (cd "$ROOT/rust/srk-render" && cargo build --release)
fi
"$RUST_BIN" \
  --tiles "$TILES" \
  --layers "$LAYERS" \
  --out "$CAND_DIR" \
  --format png

echo "[render-suite] 3/3 compare-run…"
cd "$HARNESS"
bun run scripts/compare-run.ts \
  --manifest "$MANIFEST" \
  --suite "$SUITE" \
  --ref-dir "$REF_DIR" \
  --cand-dir "$CAND_DIR"

echo "[render-suite] done"
