#!/usr/bin/env python3
"""
Compare two XYZ tile directories with SSIM + capped pixel-diff.

Exit 0 = pass, 1 = fail thresholds, 2 = usage/IO error.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image


def list_tiles(root: Path) -> dict[str, Path]:
    out: dict[str, Path] = {}
    for path in root.rglob("*"):
        if path.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
            continue
        rel = path.relative_to(root).as_posix()
        out[rel] = path
    return out


def load_rgb(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"), dtype=np.float64)


def ssim_rgb(a: np.ndarray, b: np.ndarray) -> float:
    """Mean SSIM over RGB channels (simplified, window=whole image)."""
    if a.shape != b.shape:
        raise ValueError(f"shape mismatch {a.shape} vs {b.shape}")
    scores = []
    for c in range(3):
        x = a[:, :, c]
        y = b[:, :, c]
        mu_x = x.mean()
        mu_y = y.mean()
        sig_x = x.var()
        sig_y = y.var()
        sig_xy = ((x - mu_x) * (y - mu_y)).mean()
        c1 = (0.01 * 255) ** 2
        c2 = (0.03 * 255) ** 2
        num = (2 * mu_x * mu_y + c1) * (2 * sig_xy + c2)
        den = (mu_x**2 + mu_y**2 + c1) * (sig_x + sig_y + c2)
        scores.append(float(num / den))
    return float(sum(scores) / len(scores))


def pixel_diff_fraction(a: np.ndarray, b: np.ndarray, threshold: float) -> float:
    diff = np.max(np.abs(a - b), axis=2)
    return float(np.mean(diff > threshold))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("reference", type=Path)
    ap.add_argument("candidate", type=Path)
    ap.add_argument("--out", type=Path, help="Write report.md + summary.json here")
    ap.add_argument("--min-mean-ssim", type=float, default=0.98)
    ap.add_argument("--min-tile-ssim", type=float, default=0.95)
    ap.add_argument("--max-diff-frac", type=float, default=0.02)
    ap.add_argument("--diff-threshold", type=float, default=16.0)
    ap.add_argument("--limit", type=int, default=0, help="Compare at most N tiles (0=all)")
    args = ap.parse_args()

    if not args.reference.is_dir() or not args.candidate.is_dir():
        print("reference and candidate must be directories", file=sys.stderr)
        return 2

    ref = list_tiles(args.reference)
    cand = list_tiles(args.candidate)
    common = sorted(set(ref) & set(cand))
    only_ref = sorted(set(ref) - set(cand))
    only_cand = sorted(set(cand) - set(ref))
    if args.limit and args.limit > 0:
        common = common[: args.limit]

    rows = []
    for rel in common:
        try:
            a = load_rgb(ref[rel])
            b = load_rgb(cand[rel])
            if a.shape != b.shape:
                rows.append({"tile": rel, "ok": False, "error": f"shape {a.shape} vs {b.shape}"})
                continue
            ssim = ssim_rgb(a, b)
            diff_frac = pixel_diff_fraction(a, b, args.diff_threshold)
            rows.append(
                {
                    "tile": rel,
                    "ok": True,
                    "ssim": round(ssim, 6),
                    "diff_frac": round(diff_frac, 6),
                }
            )
        except Exception as exc:  # noqa: BLE001
            rows.append({"tile": rel, "ok": False, "error": str(exc)})

    ok_rows = [r for r in rows if r.get("ok")]
    ssims = [r["ssim"] for r in ok_rows]
    diffs = [r["diff_frac"] for r in ok_rows]
    mean_ssim = float(sum(ssims) / len(ssims)) if ssims else 0.0
    min_ssim = float(min(ssims)) if ssims else 0.0
    mean_diff = float(sum(diffs) / len(diffs)) if diffs else 1.0
    worst = sorted(ok_rows, key=lambda r: r["ssim"])[:15]

    fail_reasons = []
    if only_ref or only_cand:
        fail_reasons.append(
            f"tile set mismatch: only_ref={len(only_ref)} only_cand={len(only_cand)}"
        )
    if len(ok_rows) != len(common):
        fail_reasons.append(f"load errors: {len(common) - len(ok_rows)}")
    if mean_ssim < args.min_mean_ssim:
        fail_reasons.append(f"mean SSIM {mean_ssim:.4f} < {args.min_mean_ssim}")
    if min_ssim < args.min_tile_ssim:
        fail_reasons.append(f"min SSIM {min_ssim:.4f} < {args.min_tile_ssim}")
    if mean_diff > args.max_diff_frac:
        fail_reasons.append(f"mean diff_frac {mean_diff:.4f} > {args.max_diff_frac}")

    summary = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "reference": str(args.reference),
        "candidate": str(args.candidate),
        "common_tiles": len(common),
        "only_ref": len(only_ref),
        "only_cand": len(only_cand),
        "mean_ssim": round(mean_ssim, 6),
        "min_ssim": round(min_ssim, 6),
        "mean_diff_frac": round(mean_diff, 6),
        "pass": not fail_reasons,
        "fail_reasons": fail_reasons,
        "thresholds": {
            "min_mean_ssim": args.min_mean_ssim,
            "min_tile_ssim": args.min_tile_ssim,
            "max_diff_frac": args.max_diff_frac,
            "diff_threshold": args.diff_threshold,
        },
        "worst_tiles": worst,
    }

    lines = [
        "# Tile compare report",
        "",
        f"- **Reference:** `{args.reference}`",
        f"- **Candidate:** `{args.candidate}`",
        f"- **Result:** {'PASS' if summary['pass'] else 'FAIL'}",
        f"- **Tiles compared:** {len(common)} (ref-only {len(only_ref)}, cand-only {len(only_cand)})",
        f"- **Mean SSIM:** {mean_ssim:.4f} (min {min_ssim:.4f})",
        f"- **Mean |Δ|>16 frac:** {mean_diff:.4%}",
        "",
    ]
    if fail_reasons:
        lines.append("## Failures")
        lines.append("")
        for r in fail_reasons:
            lines.append(f"- {r}")
        lines.append("")
    lines.append("## Worst tiles (by SSIM)")
    lines.append("")
    lines.append("| Tile | SSIM | Diff frac |")
    lines.append("| --- | ---: | ---: |")
    for r in worst:
        lines.append(f"| `{r['tile']}` | {r['ssim']:.4f} | {r['diff_frac']:.4%} |")
    lines.append("")

    text = "\n".join(lines) + "\n"
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "report.md").write_text(text)
        (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"Wrote {args.out / 'report.md'}", file=sys.stderr)
    print(text)
    return 0 if summary["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
