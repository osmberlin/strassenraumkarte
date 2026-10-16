#!/usr/bin/env bash
#
# Check that a style renders identical pixels regardless of the metatile layout.
#
#   docs/design-research/tools/seam_check.sh <layers> [bbox] [zoom]
#
# Renders the bbox once with --metatile 1 and once with --metatile 4 (both --gutter 1)
# and reports the share of pixels that differ by more than 8/255. Anything above
# ~0.1 % mean points at state that depends on the render extent instead of the world.
#
set -euo pipefail
LAYERS=${1:?layers}
BBOX=${2:-13.4205,52.4760,13.4240,52.4782}
Z=${3:-19}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BIN=${SRK_BIN:-"$ROOT/rust/srk-render/target/release/srk-render"}
export DB_PORT=${DB_PORT:-5433} PGPASSWORD=${PGPASSWORD:-postgres}
OUT=$(mktemp -d)
for mt in 1 4; do
  "$BIN" --bbox "$BBOX" --zmin "$Z" --zmax "$Z" --layers "$LAYERS" --metatile $mt --gutter 1 \
    --format png --out "$OUT/m$mt" --quiet --workers 4 >/dev/null 2>&1
done
python3 - "$OUT" "$Z" "$LAYERS" <<'PY'
import os, sys
import numpy as np
from PIL import Image
out, z, layers = sys.argv[1], sys.argv[2], sys.argv[3]
shares = []
worst = (0.0, "")
for x in os.listdir(f"{out}/m1/{z}"):
    for f in os.listdir(f"{out}/m1/{z}/{x}"):
        b = f"{out}/m4/{z}/{x}/{f}"
        if not os.path.exists(b):
            continue
        d = np.abs(np.asarray(Image.open(f"{out}/m1/{z}/{x}/{f}").convert("RGB")).astype(int)
                   - np.asarray(Image.open(b).convert("RGB")).astype(int)).max(-1)
        v = float((d > 8).mean())
        shares.append(v)
        worst = max(worst, (v, f"{z}/{x}/{f}"))
print(f"{layers}: {len(shares)} tiles, mean {np.mean(shares) * 100:.3f} % pixels differ, worst {worst[0] * 100:.2f} % ({worst[1]})")
PY
rm -rf "$OUT"
