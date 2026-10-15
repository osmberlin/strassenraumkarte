#!/usr/bin/env bash
#
# Render the four design-research scenes with srk-render and stitch them.
#
#   docs/design-research/tools/render_scenes.sh <layers> <out-dir> [zoom]
#
# <layers>: srk-render preset (full-approx | la | ink …)
# Writes <out-dir>/tiles/{z}/{x}/{y}.png and <out-dir>/<scene>.png
# zoom: 19 (default, 4×4 tiles per scene) or 18 (2×2 tiles around the same centre)
#
set -euo pipefail

LAYERS=${1:?layers}
OUT=${2:?out dir}
ZOOM=${3:-19}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BIN="$ROOT/rust/srk-render/target/release/srk-render"
export DB_HOST=${DB_HOST:-localhost} DB_PORT=${DB_PORT:-5433} DB_USER=${DB_USER:-postgres} DB_NAME=${DB_NAME:-strassenraumkarte}
export PGPASSWORD=${PGPASSWORD:-postgres}

# z19 scene ranges (keep in sync with make_scenes.py)
SCENES=(
  "a-herrfurthplatz 281689 281692 172043 172046"
  "b-schillerpromenade 281691 281694 172049 172052"
  "c-hasenheide-edge 281682 281685 172039 172042"
  "d-courtyard-blocks 281701 281704 172044 172047"
)

TILES=()
for s in "${SCENES[@]}"; do
  read -r name x0 x1 y0 y1 <<<"$s"
  if [[ $ZOOM == 18 ]]; then
    x0=$((x0 / 2)); x1=$((x1 / 2)); y0=$((y0 / 2)); y1=$((y1 / 2))
  fi
  for ((x = x0; x <= x1; x++)); do
    for ((y = y0; y <= y1; y++)); do
      TILES+=("$ZOOM/$x/$y")
    done
  done
done

mkdir -p "$OUT/tiles"
IFS=,
"$BIN" --tiles "${TILES[*]}" --layers "$LAYERS" --out "$OUT/tiles" --format png --gutter 1 --workers 4 --quiet
unset IFS

python3 - "$OUT" "$ZOOM" "${SCENES[@]}" <<'EOF'
import os, sys
from PIL import Image
out, zoom, scenes = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
for s in scenes:
    name, x0, x1, y0, y1 = s.split()
    x0, x1, y0, y1 = map(int, (x0, x1, y0, y1))
    if zoom == 18:
        x0, x1, y0, y1 = x0 // 2, x1 // 2, y0 // 2, y1 // 2
    im = Image.new("RGB", ((x1 - x0 + 1) * 256, (y1 - y0 + 1) * 256), (237, 237, 237))
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            p = f"{out}/tiles/{zoom}/{x}/{y}.png"
            if os.path.exists(p):
                im.paste(Image.open(p).convert("RGB"), ((x - x0) * 256, (y - y0) * 256))
    im.save(f"{out}/{name}{'' if zoom == 19 else '-z' + str(zoom)}.png")
EOF
echo "$OUT"
