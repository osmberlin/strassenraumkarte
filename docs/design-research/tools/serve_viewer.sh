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
#   AREA_NAME="Berlin · Neukölln"  title of the area (default: Berlin area with the Berlin scenes
#                        when no bbox is given, else none)
#   SCENES=berlin|none   scene list of THIS area in area.json (default berlin when the default bbox
#                        is used, keep in sync with render_scenes.sh; none otherwise). Scenes
#                        belong to an area: an area without scenes shows none.
#   VIEW_CENTER=lat,lng  where the viewer starts without #map= (default: centre of bbox)
#   VIEW_ZOOM=18         start zoom without #map= (default 18)
#   INDEX_ONLY=1         only write index.html, layers.json and area.json into OUT, no render,
#                        no server (for another tile folder, e.g. tmp/langerwehe/www with OUT=)
#   OUT=<dir>            tile folder (default tmp/design-tiles of this checkout)
#
# Writes next to the tiles: layers.json (variant folders, format, zoom range) and area.json
# (title, start view, scene list). The viewer reads both from its own folder.
#
set -euo pipefail
DEFAULT_AREA=""
[[ $# -eq 0 ]] && DEFAULT_AREA=berlin
BBOX=${1:-13.4132,52.4695,13.4465,52.4821}
PORT=${2:-8017}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BIN=${SRK_BIN:-"$ROOT/rust/srk-render/target/release/srk-render"}
OUT=${OUT:-"$ROOT/tmp/design-tiles"}
ZMAX=${ZMAX:-19}
SCENES=${SCENES:-${DEFAULT_AREA:-none}}
AREA_NAME=${AREA_NAME:-$([[ $DEFAULT_AREA ]] && echo "Berlin · Neukölln" || echo "")}
export DB_PORT=${DB_PORT:-5433} PGPASSWORD=${PGPASSWORD:-postgres}

render() { # variant preset [accent] [extra env]
  [[ -n ${VARIANTS:-} && " $VARIANTS " != *" $1 "* ]] && return
  echo "· $1"
  rm -rf "${OUT:?}/$1"
  env ${4:-} SRK_ACCENT=${3:-playground} "$BIN" --bbox "$BBOX" --zmin 16 --zmax "$ZMAX" --layers "$2" \
    --metatile 4 --gutter 1 --workers 3 --format webp --out "$OUT/$1" --quiet 2>&1 | grep '^timing' || true
}

mkdir -p "$OUT"
[[ -n ${INDEX_ONLY:-} ]] && SKIP_RENDER=1
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

write_index() { # dir: layers.json, area.json and index.html for the viewer
  env BBOX="$BBOX" SCENES="$SCENES" AREA_NAME="$AREA_NAME" VIEW_CENTER="${VIEW_CENTER:-}" VIEW_ZOOM="${VIEW_ZOOM:-18}" \
    python3 - "$1" <<'PY'
import json, math, os, sys
out = sys.argv[1]

# layers.json: which variant folders exist, their tile format and zoom range
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

# area.json: start view and scene jump list (z19 tile ranges: key, label, x0, x1, y0, y1)
def lon(x): return x / 2 ** 19 * 360 - 180
def lat(y): return 180 / math.pi * math.atan(math.sinh(math.pi * (1 - 2 * y / 2 ** 19)))
BERLIN_SCENES = [
    ("a", "Herrfurthplatz", 281689, 281692, 172043, 172046),
    ("b", "Schillerpromenade", 281691, 281694, 172049, 172052),
    ("c", "Hasenheide-Rand", 281682, 281685, 172039, 172042),
    ("d", "Hofblöcke", 281701, 281704, 172044, 172047),
    ("e", "Richardplatz", 281722, 281725, 172051, 172054),
    ("f", "Körnerpark", 281712, 281715, 172058, 172061),
]
scenes = []
if os.environ.get("SCENES") == "berlin":
    for key, label, x0, x1, y0, y1 in BERLIN_SCENES:
        scenes.append({"id": key, "label": label,
                       "bounds": [[lat(y1 + 1), lon(x0)], [lat(y0), lon(x1 + 1)]]})
if os.environ.get("VIEW_CENTER"):
    center = [float(v) for v in os.environ["VIEW_CENTER"].split(",")]
else:
    w, s, e, n = (float(v) for v in os.environ["BBOX"].split(","))  # west,south,east,north
    center = [(s + n) / 2, (w + e) / 2]
w, s, e, n = (float(v) for v in os.environ["BBOX"].split(","))  # west,south,east,north
area = {"title": os.environ.get("AREA_NAME", ""), "center": center,
        "zoom": int(os.environ["VIEW_ZOOM"]),
        "bounds": [[s, w], [n, e]],  # the map cannot be panned out of this box (maxBounds)
        "scenes": scenes}
json.dump(area, open(os.path.join(out, "area.json"), "w"), indent=1, ensure_ascii=False)
print("area: centre", center, "zoom", area["zoom"], "scenes", len(scenes))
PY
  cp "$ROOT/docs/design-research/tools/viewer.html" "$1/index.html"
}
write_index "$OUT"
[[ -n ${INDEX_ONLY:-} ]] && { echo "→ $OUT written (no server)"; exit 0; }
echo "→ http://127.0.0.1:$PORT/   (compare: #mode=swipe&a=la&b=qgis)"
cd "$OUT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1
