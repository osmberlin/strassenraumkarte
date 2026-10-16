#!/usr/bin/env bash
#
# Save one iteration of a style exploration as a step folder.
#
#   docs/design-research/tools/save_step.sh <exploration-dir> <NN-slug> <render-dir> <readme.md> [previous-step]
#
# Writes <exploration-dir>/steps/<NN-slug>/{sheet.jpg,detail.jpg,README.md}
# sheet.jpg  = scenes A–D (2×2), sheet-ef.jpg = scenes E+F, detail.jpg = 1:1 crop of scene A
#
# previous-step (optional): slug or folder of an earlier step, or "auto" for the step
# before this one → before-after.jpg (detail and sheet of both steps, side by side).
#
set -euo pipefail
EXP=${1:?exploration dir}
STEP=${2:?step slug}
RUN=${3:?render dir}
README=${4:?readme file}
PREV=${5:-}
OUT="$EXP/steps/$STEP"
mkdir -p "$OUT"
magick montage "$RUN/a-herrfurthplatz.png" "$RUN/b-schillerpromenade.png" "$RUN/c-hasenheide-edge.png" "$RUN/d-courtyard-blocks.png" \
  -tile 2x2 -geometry 700x700+4+4 -background "#ffffff" -quality 74 "$OUT/sheet.jpg"
magick "$RUN/a-herrfurthplatz.png" -crop 560x560+380+300 +repage -quality 85 "$OUT/detail.jpg"
if [[ -f "$RUN/e-richardplatz.png" && -f "$RUN/f-koernerpark.png" ]]; then
  magick montage "$RUN/e-richardplatz.png" "$RUN/f-koernerpark.png" \
    -tile 2x1 -geometry 700x700+4+4 -background "#ffffff" -quality 74 "$OUT/sheet-ef.jpg"
fi
cp "$README" "$OUT/README.md"

if [[ -n $PREV ]]; then
  if [[ $PREV == auto ]]; then
    # latest earlier step that has a detail.jpg
    PREV=""
    for d in $(find "$EXP/steps" -mindepth 1 -maxdepth 1 -type d | sort); do
      [[ $d == "$OUT" ]] && break
      [[ -f $d/detail.jpg ]] && PREV=$d
    done
  elif [[ ! -d $PREV ]]; then
    PREV="$EXP/steps/$PREV"
  fi
  if [[ -n $PREV && -f $PREV/detail.jpg ]]; then
    ROWS=(-label "vorher · $(basename "$PREV")" "$PREV/detail.jpg" -label "nachher · $STEP" "$OUT/detail.jpg")
    [[ -f $PREV/sheet.jpg ]] && ROWS+=(-label "" "$PREV/sheet.jpg" -label "" "$OUT/sheet.jpg")
    magick montage -font /System/Library/Fonts/Supplemental/Arial.ttf -pointsize 20 "${ROWS[@]}" \
      -tile 2x -geometry 560x560+6+6 -background "#ffffff" -quality 72 "$OUT/before-after.jpg"
  else
    echo "no previous step with detail.jpg (${PREV:-none}) — skipping before-after.jpg" >&2
  fi
fi
echo "$OUT"
