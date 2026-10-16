#!/usr/bin/env bash
#
# Golden-image regression check for the design-research presets (la, ink + variants).
#
#   docs/design-research/tools/regress.sh [--update] [--only <case>] [--threshold <pct>] [--no-seam] [--keep]
#
# Renders a fixed tile set (2 z19 tiles + 1 z17 tile per scene) for every case below to PNG
# and compares each tile with tmp/regress-baseline/<case>/. A tile regresses when more than
# <pct> % of its pixels (default 0.1) differ by more than 8/255 in any channel. Afterwards
# it runs seam_check.sh (metatile 1 vs 4) once per preset and fails above 0.1 % mean.
#
#   --update     render twice, check the two runs are identical (determinism), then make the
#                result the new baseline. Do this after an intended style change.
#   --only la    run only cases whose name starts with "la" (or "ink", "ink-white", …)
#   --no-seam    skip the metatile seam check
#   --keep       keep tmp/regress-current/ (otherwise deleted; diff images of regressed tiles
#                always stay in tmp/regress-diff/)
#
# Exit code: 0 ok, 1 regression / seam / determinism failure, 2 missing baseline.
#
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TOOLS="$ROOT/docs/design-research/tools"
BIN="$ROOT/rust/srk-render/target/release/srk-render"
BASE="$ROOT/tmp/regress-baseline"
CUR="$ROOT/tmp/regress-current"
DIFF="$ROOT/tmp/regress-diff"
export DB_HOST=${DB_HOST:-localhost} DB_PORT=${DB_PORT:-5433} DB_USER=${DB_USER:-postgres} DB_NAME=${DB_NAME:-strassenraumkarte}
export PGPASSWORD=${PGPASSWORD:-postgres}

UPDATE=0 ONLY="" THRESHOLD=0.1 SEAM=1 KEEP=0
while (($#)); do
  case $1 in
    --update) UPDATE=1 ;;
    --only) ONLY=${2:?}; shift ;;
    --threshold) THRESHOLD=${2:?}; shift ;;
    --no-seam) SEAM=0 ;;
    --keep) KEEP=1 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -x $BIN ]] || { echo "build first: cd rust/srk-render && cargo build --release" >&2; exit 2; }

# name | --layers | env assignments (space separated, may be empty)
CASES=(
  "la|la|"
  "la-vivid|la|SRK_LA_PALETTE=vivid"
  "ink|ink|"
  "ink-white|ink|SRK_INK_PAPER=white"
  "ink-oblique|ink|SRK_INK_OBLIQUE=freestanding"
  "ink-accent-tree|ink|SRK_ACCENT=tree"
)

# Per scene (see render_scenes.sh): two inner z19 tiles and the z17 tile that holds them.
TILES=(
  19/281690/172044 19/281691/172045 17/70422/43011   # a-herrfurthplatz
  19/281692/172050 19/281693/172051 17/70423/43012   # b-schillerpromenade
  19/281683/172040 19/281684/172041 17/70420/43010   # c-hasenheide-edge
  19/281702/172045 19/281703/172046 17/70425/43011   # d-courtyard-blocks
  19/281723/172052 19/281724/172053 17/70430/43013   # e-richardplatz
  19/281713/172059 19/281714/172060 17/70428/43014   # f-koernerpark
)

render_case() { # <layers> <env> <out>
  local IFS=,
  # shellcheck disable=SC2086
  env $2 "$BIN" --tiles "${TILES[*]}" --layers "$1" --out "$3" --format png --gutter 1 --workers 4 --quiet >/dev/null 2>&1
}

compare() { # <a-dir> <b-dir> <diff-dir|-> → prints "tiles changed worst_pct worst_tile mean_abs missing"
  python3 - "$1" "$2" "$3" "$THRESHOLD" <<'PY'
import os, sys
import numpy as np
from PIL import Image
a, b, diff_dir, thr = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
n = changed = missing = 0
worst, worst_tile, mean_abs = 0.0, "-", 0.0
for root, _, files in os.walk(a):
    for f in sorted(files):
        if not f.endswith(".png"):
            continue
        rel = os.path.relpath(os.path.join(root, f), a)
        pb = os.path.join(b, rel)
        n += 1
        if not os.path.exists(pb):
            missing += 1
            continue
        ia = np.asarray(Image.open(os.path.join(a, rel)).convert("RGB")).astype(int)
        ib = np.asarray(Image.open(pb).convert("RGB")).astype(int)
        d = np.abs(ia - ib).max(-1)
        share = float((d > 8).mean()) * 100
        mean_abs += float(d.mean())
        if share > worst:
            worst, worst_tile = share, rel[:-4]
        if share > thr:
            changed += 1
            if diff_dir != "-":
                out = os.path.join(diff_dir, rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                mask = np.where(d > 8, 255, 0).astype(np.uint8)
                red = np.stack([np.maximum(mask, (ib.mean(-1) * 0.4).astype(np.uint8)), (ib.mean(-1) * 0.4).astype(np.uint8), (ib.mean(-1) * 0.4).astype(np.uint8)], -1)
                Image.fromarray(np.concatenate([ib, ia, red], 1).astype(np.uint8)).save(out)
print(n, changed, f"{worst:.3f}", worst_tile, f"{mean_abs / max(n, 1):.3f}", missing)
PY
}

FAIL=0
rm -rf "$CUR" "$DIFF"
mkdir -p "$CUR"
printf '%-18s %6s %8s %10s  %-22s %s\n' case tiles changed "worst %" "worst tile" status
printf '%-18s %6s %8s %10s  %-22s %s\n' ------------------ ------ -------- ---------- ---------------------- ------
for c in "${CASES[@]}"; do
  IFS='|' read -r name layers envs <<<"$c"
  [[ -n $ONLY && $name != "$ONLY"* ]] && continue
  t0=$SECONDS
  render_case "$layers" "$envs" "$CUR/$name"
  if ((UPDATE)); then
    # determinism: a second render must be pixel-identical
    render_case "$layers" "$envs" "$CUR/$name.again"
    if diff -rq "$CUR/$name" "$CUR/$name.again" >/dev/null; then
      same=1
    else
      same=0
    fi
    rm -rf "$CUR/$name.again"
    if ((!same)); then
      status="NONDETERMINISTIC (baseline kept)"
      FAIL=1
    else
      rm -rf "${BASE:?}/$name"
      mkdir -p "$BASE"
      mv "$CUR/$name" "$BASE/$name"
      status="baseline updated"
    fi
  elif [[ ! -d $BASE/$name ]]; then
    status="NO BASELINE (run --update)"
    ((FAIL == 0)) && FAIL=2
  else
    read -r n changed worst wtile _ missing < <(compare "$CUR/$name" "$BASE/$name" "$DIFF/$name")
    if ((changed > 0 || missing > 0)); then
      status="REGRESSION"
      FAIL=1
    else
      status="ok"
    fi
  fi
  printf '%-18s %6s %8s %10s  %-22s %s (%ss)\n' "$name" "${n:--}" "${changed:--}" "${worst:--}" "${wtile:--}" "$status" $((SECONDS - t0))
done
if ((UPDATE)); then
  git -C "$ROOT" rev-parse --short HEAD >"$BASE/COMMIT" 2>/dev/null || true
fi

if ((SEAM)); then
  echo
  echo "seam check (metatile 1 vs 4, threshold 0.1 % mean):"
  for p in la ink; do
    [[ -n $ONLY && $p != "${ONLY%%-*}" ]] && continue
    line=$("$TOOLS/seam_check.sh" "$p")
    mean=$(sed -n 's/.*mean \([0-9.]*\) %.*/\1/p' <<<"$line")
    if [[ -z $mean ]] || awk -v m="$mean" 'BEGIN { exit !(m > 0.1) }'; then
      echo "  SEAM FAIL  $line"
      FAIL=1
    else
      echo "  ok         $line"
    fi
  done
fi

((KEEP)) || rm -rf "$CUR"
[[ -d $DIFF ]] && echo && echo "diff images (baseline | current | changed pixels in red): $DIFF"
exit "$FAIL"
