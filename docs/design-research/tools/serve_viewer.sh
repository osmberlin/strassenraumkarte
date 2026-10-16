#!/usr/bin/env bash
#
# Render the design-research styles for an area and serve them in a small Leaflet viewer.
#
#   docs/design-research/tools/serve_viewer.sh [bbox] [port]
#
# Tiles go to tmp/design-tiles/<variant>/{z}/{x}/{y}.webp (gitignored); then
# http://127.0.0.1:<port>/ shows viewer.html: one or two layers (swipe / side by side),
# scene jump list, state in the URL. The default bbox covers all six scenes.
#
#   SKIP_RENDER=1        only serve existing tiles
#   VARIANTS="la ink"    render only these variants (default: all, see render calls below)
#   ZMAX=20              highest zoom to render (default 19)
#   QGIS_TILES=<dir>     today's QGIS tiles as reference layer "qgis" (default: render/tiles of
#                        this checkout or of the main checkout, if present; jpg z15–20)
#
set -euo pipefail
BBOX=${1:-13.4132,52.4695,13.4465,52.4821}
PORT=${2:-8017}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BIN="$ROOT/rust/srk-render/target/release/srk-render"
OUT="$ROOT/tmp/design-tiles"
ZMAX=${ZMAX:-19}
export DB_PORT=${DB_PORT:-5433} PGPASSWORD=${PGPASSWORD:-postgres}

render() { # variant preset [accent] [extra env]
  [[ -n ${VARIANTS:-} && " $VARIANTS " != *" $1 "* ]] && return
  echo "· $1"
  rm -rf "${OUT:?}/$1"
  env ${4:-} SRK_ACCENT=${3:-playground} "$BIN" --bbox "$BBOX" --zmin 16 --zmax "$ZMAX" --layers "$2" \
    --metatile 4 --gutter 1 --workers 3 --format webp --out "$OUT/$1" --quiet 2>&1 | grep '^timing' || true
}

mkdir -p "$OUT"
if [[ -z ${SKIP_RENDER:-} ]]; then
  render la la
  render la-vivid la playground SRK_LA_PALETTE=vivid
  render ink ink
  render ink-oblique ink playground SRK_INK_OBLIQUE=freestanding
  render ink-white ink playground SRK_INK_PAPER=white
  render ink-bench ink bench
  render ink-tree ink tree
  render full-approx full-approx
fi

# reference layer: today's QGIS tiles (symlink, nothing is copied)
MAIN=$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
for q in "${QGIS_TILES:-}" "$ROOT/render/tiles" "${MAIN:-/nonexistent}/render/tiles"; do
  if [[ -n $q && -d $q/19 ]]; then
    ln -sfn "$q" "$OUT/qgis"
    echo "· qgis → $q"
    break
  fi
done

# layers.json: which variant folders exist, their tile format and zoom range
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
layers = []
for name in sorted(os.listdir(out)):
    d = os.path.join(out, name)
    if not os.path.isdir(d):
        continue
    zs = sorted(int(z) for z in os.listdir(d) if z.isdigit())
    if not zs:
        continue
    ext = "webp"
    zdir = os.path.join(d, str(zs[-1]))
    for x in os.scandir(zdir):
        f = next(os.scandir(x.path), None)
        if f:
            ext = f.name.rsplit(".", 1)[-1]
            break
    layers.append({"id": name, "ext": ext, "zmin": zs[0], "zmax": zs[-1]})
json.dump(layers, open(os.path.join(out, "layers.json"), "w"), indent=1)
print("layers:", " ".join(f"{l['id']}(z{l['zmin']}–{l['zmax']})" for l in layers))
PY
cp "$ROOT/docs/design-research/tools/viewer.html" "$OUT/index.html"
echo "→ http://127.0.0.1:$PORT/   (compare: #mode=swipe&a=la&b=qgis)"
cd "$OUT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1
