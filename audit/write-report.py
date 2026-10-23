#!/usr/bin/env python3
"""Generate report.md + findings.json from an audit run directory."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_steps(path: Path) -> list[dict[str, Any]]:
    steps: list[dict[str, Any]] = []
    if not path.is_file():
        return steps
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("event") == "step":
            steps.append(row)
    return steps


def fmt_ms(ms: int | float) -> str:
    ms = int(ms)
    if ms < 1000:
        return f"{ms} ms"
    s = ms / 1000.0
    if s < 60:
        return f"{s:.1f} s"
    m = int(s // 60)
    rem = s - 60 * m
    return f"{m}m {rem:04.1f}s"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "run_dir",
        nargs="?",
        help="audit/runs/<id> (default: latest under audit/runs)",
    )
    p.add_argument(
        "--reference",
        default=None,
        help="Path to reference_times.json",
    )
    args = p.parse_args()

    audit_root = Path(__file__).resolve().parent
    runs_root = audit_root / "runs"
    if args.run_dir:
        run_dir = Path(args.run_dir)
        if not run_dir.is_absolute():
            run_dir = Path.cwd() / run_dir
    else:
        if not runs_root.is_dir():
            print("No audit/runs directory yet.", file=sys.stderr)
            return 1
        candidates = sorted(
            [d for d in runs_root.iterdir() if d.is_dir() and (d / "steps.jsonl").is_file()],
            key=lambda d: d.stat().st_mtime,
        )
        if not candidates:
            print("No completed audit runs found under audit/runs/.", file=sys.stderr)
            return 1
        run_dir = candidates[-1]

    ref_path = Path(args.reference) if args.reference else audit_root / "reference_times.json"
    refs = {}
    if ref_path.is_file():
        refs = {k: v for k, v in json.loads(ref_path.read_text(encoding="utf-8")).items() if not k.startswith("_")}

    meta = {}
    meta_path = run_dir / "meta.json"
    if meta_path.is_file():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))

    steps = load_steps(run_dir / "steps.jsonl")
    timed = [s for s in steps if s.get("status") not in ("note",)]
    notes = [s for s in steps if s.get("status") == "note"]

    by_phase: dict[str, int] = {}
    for s in timed:
        phase = str(s.get("phase") or "other")
        by_phase[phase] = by_phase.get(phase, 0) + int(s.get("duration_ms") or 0)

    total_ms = sum(int(s.get("duration_ms") or 0) for s in timed)
    ranked = sorted(timed, key=lambda s: int(s.get("duration_ms") or 0), reverse=True)

    findings: list[dict[str, Any]] = []

    # Top contributors
    for s in ranked[:8]:
        dur = int(s.get("duration_ms") or 0)
        pct = (100.0 * dur / total_ms) if total_ms else 0.0
        if pct >= 5.0 or dur >= 5000:
            findings.append(
                {
                    "severity": "info" if pct < 15 else "attention",
                    "name": s.get("name"),
                    "phase": s.get("phase"),
                    "duration_ms": dur,
                    "pct_of_timed_steps": round(pct, 1),
                    "message": f"{s.get('name')} took {fmt_ms(dur)} ({pct:.1f}% of timed steps)",
                }
            )

    # Reference comparison (bbox size differs from Neukölln — flag large multiples)
    for s in timed:
        name = str(s.get("name") or "")
        ref = refs.get(name)
        if not ref or not isinstance(ref, dict):
            continue
        ref_s = float(ref.get("ref_seconds") or 0)
        if ref_s <= 0:
            continue
        dur_s = int(s.get("duration_ms") or 0) / 1000.0
        ratio = dur_s / ref_s if ref_s else 0
        if ratio >= 2.0 and dur_s >= 2.0:
            findings.append(
                {
                    "severity": "regression_suspect",
                    "name": name,
                    "phase": s.get("phase"),
                    "duration_ms": int(s.get("duration_ms") or 0),
                    "ref_seconds": ref_s,
                    "ratio_vs_ref": round(ratio, 2),
                    "message": (
                        f"{name} is {ratio:.1f}× the Neukölln reference "
                        f"({fmt_ms(dur_s * 1000)} vs ~{fmt_ms(ref_s * 1000)}; "
                        f"compare bbox size before treating as a regression)"
                    ),
                }
            )
        elif ratio <= 0.25 and ref_s >= 5 and dur_s >= 0:
            findings.append(
                {
                    "severity": "faster_than_ref",
                    "name": name,
                    "phase": s.get("phase"),
                    "duration_ms": int(s.get("duration_ms") or 0),
                    "ref_seconds": ref_s,
                    "ratio_vs_ref": round(ratio, 2),
                    "message": (
                        f"{name} is much faster than Neukölln reference "
                        f"({fmt_ms(dur_s * 1000)} vs ~{fmt_ms(ref_s * 1000)}) — likely smaller bbox"
                    ),
                }
            )

    failed = [s for s in timed if s.get("status") == "fail"]
    for s in failed:
        findings.append(
            {
                "severity": "fail",
                "name": s.get("name"),
                "phase": s.get("phase"),
                "duration_ms": int(s.get("duration_ms") or 0),
                "exit_code": s.get("exit_code"),
                "message": f"Step failed: {s.get('name')} (exit {s.get('exit_code')})",
            }
        )

    # Improvement suggestions from phase mix
    if by_phase:
        top_phase = max(by_phase.items(), key=lambda kv: kv[1])
        phase_pct = 100.0 * top_phase[1] / total_ms if total_ms else 0
        findings.append(
            {
                "severity": "focus",
                "name": top_phase[0],
                "phase": top_phase[0],
                "duration_ms": top_phase[1],
                "pct_of_timed_steps": round(phase_pct, 1),
                "message": (
                    f"Largest phase is '{top_phase[0]}' ({fmt_ms(top_phase[1])}, "
                    f"{phase_pct:.1f}%). Optimise steps in that phase first."
                ),
            }
        )

    # Slowest metatile (if render audit present)
    meta_path_jsonl = run_dir / "render_metatiles.jsonl"
    if meta_path_jsonl.is_file():
        slow: list[dict[str, Any]] = []
        for line in meta_path_jsonl.read_text(encoding="utf-8").splitlines():
            try:
                slow.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        if slow:
            slow.sort(key=lambda r: int(r.get("duration_ms") or 0), reverse=True)
            top = slow[0]
            findings.append(
                {
                    "severity": "info",
                    "name": "slowest_metatile",
                    "phase": "render",
                    "duration_ms": int(top.get("duration_ms") or 0),
                    "message": (
                        f"Slowest metatile: z{top.get('z')} "
                        f"({top.get('x0')},{top.get('y0')})–({top.get('x1')},{top.get('y1')}) "
                        f"took {fmt_ms(int(top.get('duration_ms') or 0))} "
                        f"({top.get('tiles')} tiles)"
                    ),
                }
            )

    findings_path = run_dir / "findings.json"
    findings_path.write_text(
        json.dumps(
            {
                "run_id": meta.get("run_id") or run_dir.name,
                "total_duration_ms": total_ms,
                "findings": findings,
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    lines: list[str] = []
    lines.append(f"# Performance audit: `{run_dir.name}`")
    lines.append("")
    lines.append("## Meta")
    lines.append("")
    lines.append(f"- **Status:** {meta.get('status', 'unknown')}")
    lines.append(f"- **Started:** {meta.get('started_at', '—')}")
    lines.append(f"- **Finished:** {meta.get('finished_at', '—')}")
    lines.append(f"- **Git:** {meta.get('git_sha') or '—'}")
    if meta.get("label"):
        lines.append(f"- **Label:** {meta['label']}")
    env = meta.get("env") or {}
    if env:
        lines.append(f"- **Env:** `{json.dumps(env, ensure_ascii=False)}`")
    host = meta.get("host") or {}
    if host:
        mem = host.get("mem_bytes")
        mem_s = f"{mem / (1024**3):.1f} GiB" if isinstance(mem, int) else "—"
        lines.append(
            f"- **Host:** {host.get('system')} {host.get('machine')}, "
            f"{host.get('cpu_count')} CPUs, mem {mem_s}"
        )
    lines.append(f"- **Sum of timed steps:** {fmt_ms(total_ms)}")
    lines.append("")

    lines.append("## Findings")
    lines.append("")
    if not findings:
        lines.append("_No automated findings._")
    else:
        for f in findings:
            lines.append(f"- **[{f['severity']}]** {f['message']}")
    lines.append("")

    lines.append("## Time by phase")
    lines.append("")
    lines.append("| Phase | Duration | Share |")
    lines.append("| --- | ---: | ---: |")
    for phase, dur in sorted(by_phase.items(), key=lambda kv: kv[1], reverse=True):
        pct = 100.0 * dur / total_ms if total_ms else 0
        lines.append(f"| `{phase}` | {fmt_ms(dur)} | {pct:.1f}% |")
    lines.append("")

    lines.append("## Steps (slowest first)")
    lines.append("")
    lines.append("| Step | Phase | Duration | Share | Status | vs ref |")
    lines.append("| --- | --- | ---: | ---: | --- | ---: |")
    for s in ranked:
        dur = int(s.get("duration_ms") or 0)
        pct = 100.0 * dur / total_ms if total_ms else 0
        name = str(s.get("name") or "")
        ref = refs.get(name) if isinstance(refs.get(name), dict) else None
        vs = "—"
        if ref and float(ref.get("ref_seconds") or 0) > 0:
            vs = f"{(dur / 1000.0) / float(ref['ref_seconds']):.2f}×"
        lines.append(
            f"| `{name}` | `{s.get('phase')}` | {fmt_ms(dur)} | {pct:.1f}% | "
            f"{s.get('status')} | {vs} |"
        )
    lines.append("")

    if notes:
        lines.append("## Notes / snapshots")
        lines.append("")
        for s in notes:
            detail = s.get("detail") or {}
            lines.append(f"- `{s.get('name')}`: `{json.dumps(detail, ensure_ascii=False)}`")
        lines.append("")

    lines.append("## Raw data")
    lines.append("")
    lines.append(f"- `{run_dir / 'meta.json'}`")
    lines.append(f"- `{run_dir / 'steps.jsonl'}`")
    lines.append(f"- `{run_dir / 'findings.json'}`")
    if (run_dir / "console.log").is_file():
        lines.append(f"- `{run_dir / 'console.log'}`")
    if (run_dir / "render_summary.json").is_file():
        lines.append(f"- `{run_dir / 'render_summary.json'}`")
    if meta_path_jsonl.is_file():
        lines.append(f"- `{meta_path_jsonl}`")
    lines.append("")
    lines.append(
        "Reference times are Neukölln-area wall times from script comments; "
        "scale expectations with bbox size before calling a step a regression."
    )
    lines.append("")

    report_path = run_dir / "report.md"
    report_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {report_path}")
    print(f"Wrote {findings_path}")
    print(f"Timed steps: {len(timed)}, total {fmt_ms(total_ms)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
