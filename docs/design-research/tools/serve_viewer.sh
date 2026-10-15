#!/usr/bin/env bash
#
# Render the design-research styles for an area and serve them in a small Leaflet viewer.
#
#   docs/design-research/tools/serve_viewer.sh [bbox] [port]
#
# Tiles go to tmp/design-tiles/<variant>/{z}/{x}/{y}.webp (gitignored); then
# http://127.0.0.1:<port>/ shows viewer.html with one layer per variant.
# Set SKIP_RENDER=1 to only serve existing tiles.
#
set -euo pipefail
BBOX=${1:-13.4132,52.4715,13.4312,52.4821}
PORT=${2:-8017}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BIN="$ROOT/rust/srk-render/target/release/srk-render"
OUT="$ROOT/tmp/design-tiles"
export DB_PORT=${DB_PORT:-5433} PGPASSWORD=${PGPASSWORD:-postgres}

render() { # variant preset [accent] [extra env]
  rm -rf "${OUT:?}/$1"
  env ${4:-} SRK_ACCENT=${3:-playground} "$BIN" --bbox "$BBOX" --zmin 16 --zmax 19 --layers "$2" \
    --metatile 4 --gutter 1 --workers 3 --format webp --out "$OUT/$1" --quiet 2>&1 | grep '^timing' || true
}

if [[ -z ${SKIP_RENDER:-} ]]; then
  mkdir -p "$OUT"
  render la la
  render la-vivid la playground SRK_LA_PALETTE=vivid
  render ink ink
  render ink-oblique ink playground SRK_INK_OBLIQUE=freestanding
  render ink-white ink playground SRK_INK_PAPER=white
  render ink-bench ink bench
  render ink-tree ink tree
  render full-approx full-approx
fi
cp "$ROOT/docs/design-research/tools/viewer.html" "$OUT/index.html"
echo "→ http://127.0.0.1:$PORT/"
cd "$OUT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1
