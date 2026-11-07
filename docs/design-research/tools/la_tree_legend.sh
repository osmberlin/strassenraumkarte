#!/usr/bin/env bash
#
# Legend of the LA tree symbols (one per genus), both palettes, with names.
#
#   docs/design-research/tools/la_tree_legend.sh <out.png>
#
# The symbols come from the real renderer code (ignored test `la_tree_legend` in
# style_la_extra.rs); the names are added here with Pillow.
#
set -euo pipefail
OUT=${1:?out.png}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMP=$(mktemp -d)
cd "$ROOT/rust/srk-render"
SRK_LA_LEGEND="$TMP/sage.png" cargo test --release --quiet la_tree_legend -- --ignored >/dev/null
SRK_LA_PALETTE=vivid SRK_LA_LEGEND="$TMP/vivid.png" cargo test --release --quiet la_tree_legend -- --ignored >/dev/null
python3 - "$TMP" "$OUT" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
tmp, out = sys.argv[1], sys.argv[2]
names = ["Tilia · lime", "Acer · maple", "Betula · birch", "Quercus · oak", "Platanus · plane", "Prunus, Malus …",
         "Salix · willow", "Carpinus, Fagus", "Robinia, Fraxinus", "Pinus, Picea …", "no genus (by id)", "no genus (by id)"]
try:
    font = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 11, index=5)
except OSError:
    font = ImageFont.load_default()
ims = []
for p in ("sage", "vivid"):
    im = Image.open(f"{tmp}/{p}.png").convert("RGB")
    d = ImageDraw.Draw(im)
    for i, n in enumerate(names):
        d.text(((i % 6) * 120 + 60, (i // 6) * 120 + 108), n, fill=(95, 94, 87), font=font, anchor="mm")
    ims.append(im)
w, h = ims[0].size
sheet = Image.new("RGB", (w, h * 2 + 6), (255, 255, 255))
sheet.paste(ims[0], (0, 0))
sheet.paste(ims[1], (0, h + 6))
sheet.save(out)
PY
rm -rf "$TMP"
echo "$OUT"
