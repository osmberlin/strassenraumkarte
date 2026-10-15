#!/usr/bin/env bash
#
# Save one iteration of a style exploration as a step folder.
#
#   docs/design-research/tools/save_step.sh <exploration-dir> <NN-slug> <render-dir> <readme.md>
#
# Writes <exploration-dir>/steps/<NN-slug>/{sheet.jpg,detail.jpg,README.md}
# sheet.jpg  = the four scenes (2×2), detail.jpg = 1:1 crop of scene A (church + square)
#
set -euo pipefail
EXP=${1:?exploration dir}
STEP=${2:?step slug}
RUN=${3:?render dir}
README=${4:?readme file}
OUT="$EXP/steps/$STEP"
mkdir -p "$OUT"
magick montage "$RUN/a-herrfurthplatz.png" "$RUN/b-schillerpromenade.png" "$RUN/c-hasenheide-edge.png" "$RUN/d-courtyard-blocks.png" \
  -tile 2x2 -geometry 760x760+4+4 -background '#ffffff' -quality 80 "$OUT/sheet.jpg"
magick "$RUN/a-herrfurthplatz.png" -crop 560x560+380+300 +repage -quality 85 "$OUT/detail.jpg"
cp "$README" "$OUT/README.md"
echo "$OUT"
