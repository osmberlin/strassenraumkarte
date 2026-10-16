#!/usr/bin/env bash
#
# Render the six design-research scenes with srk-render and stitch them.
#
#   docs/design-research/tools/render_scenes.sh [options] <layers> <out-dir> [zoom]
#
# <layers>: srk-render preset (full-approx | la | ink …)
# Writes <out-dir>/tiles/{z}/{x}/{y}.png and <out-dir>/<scene>.png
# zoom: 19 (default, 4×4 tiles per scene) or lower (same area, fewer tiles: 18 → 2×2, 17 → 1×1)
#
# Options:
#   --env KEY=VALUE   pass a variant switch to srk-render (repeatable), e.g.
#                     --env SRK_LA_PALETTE=vivid  --env SRK_INK_OBLIQUE=freestanding
#                     --env SRK_INK_PAPER=white   --env SRK_ACCENT=bench
#                     --env SRK_CARS=on (parked cars, both presets)
#                     (plain environment variables work too; --env just keeps them visible)
#   --scenes a,c      only these scenes (letters a–f); default all
#   --png-only        delete the tile folder after stitching (keeps only the scene PNGs)
#
set -euo pipefail

ENVS=()
ONLY=""
PNG_ONLY=""
while [[ ${1:-} == --* ]]; do
  case $1 in
    --env) ENVS+=("${2:?--env KEY=VALUE}"); shift 2 ;;
    --scenes) ONLY=${2:?--scenes a,b}; shift 2 ;;
    --png-only) PNG_ONLY=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
LAYERS=${1:?layers}
OUT=${2:?out dir}
ZOOM=${3:-19}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BIN=${SRK_BIN:-"$ROOT/rust/srk-render/target/release/srk-render"}
export DB_HOST=${DB_HOST:-localhost} DB_PORT=${DB_PORT:-5433} DB_USER=${DB_USER:-postgres} DB_NAME=${DB_NAME:-strassenraumkarte}
export PGPASSWORD=${PGPASSWORD:-postgres}

# z19 scene ranges (keep in sync with make_scenes.py and viewer.html)
ALL_SCENES=(
  "a-herrfurthplatz 281689 281692 172043 172046"
  "b-schillerpromenade 281691 281694 172049 172052"
  "c-hasenheide-edge 281682 281685 172039 172042"
  "d-courtyard-blocks 281701 281704 172044 172047"
  "e-richardplatz 281722 281725 172051 172054"
  "f-koernerpark 281712 281715 172058 172061"
)
SCENES=()
for s in "${ALL_SCENES[@]}"; do
  [[ -z $ONLY || ",$ONLY," == *",${s:0:1},"* ]] && SCENES+=("$s")
done
((${#SCENES[@]})) || { echo "no scene matches --scenes $ONLY" >&2; exit 2; }

TILES=()
for s in "${SCENES[@]}"; do
  read -r name x0 x1 y0 y1 <<<"$s"
  if ((ZOOM < 19)); then
    d=$((1 << (19 - ZOOM)))
    x0=$((x0 / d)); x1=$((x1 / d)); y0=$((y0 / d)); y1=$((y1 / d))
  fi
  for ((x = x0; x <= x1; x++)); do
    for ((y = y0; y <= y1; y++)); do
      TILES+=("$ZOOM/$x/$y")
    done
  done
done

mkdir -p "$OUT/tiles"
TILE_LIST=$(IFS=,; echo "${TILES[*]}")
env ${ENVS[@]+"${ENVS[@]}"} "$BIN" --tiles "$TILE_LIST" --layers "$LAYERS" --out "$OUT/tiles" --format png --gutter 1 --workers 4 --quiet

python3 - "$OUT" "$ZOOM" "${SCENES[@]}" <<'EOF'
import os, sys
from PIL import Image
out, zoom, scenes = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
for s in scenes:
    name, x0, x1, y0, y1 = s.split()
    x0, x1, y0, y1 = map(int, (x0, x1, y0, y1))
    if zoom < 19:
        d = 1 << (19 - zoom)
        x0, x1, y0, y1 = x0 // d, x1 // d, y0 // d, y1 // d
    im = Image.new("RGB", ((x1 - x0 + 1) * 256, (y1 - y0 + 1) * 256), (237, 237, 237))
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            p = f"{out}/tiles/{zoom}/{x}/{y}.png"
            if os.path.exists(p):
                im.paste(Image.open(p).convert("RGB"), ((x - x0) * 256, (y - y0) * 256))
    im.save(f"{out}/{name}{'' if zoom == 19 else '-z' + str(zoom)}.png")
EOF
[[ -n $PNG_ONLY ]] && rm -rf "${OUT:?}/tiles"
echo "$OUT"
