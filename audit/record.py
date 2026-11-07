#!/usr/bin/env python3
"""Append performance audit events (meta + steps.jsonl)."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def parse_detail(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {"raw": raw}
    return data if isinstance(data, dict) else {"value": data}


def read_json(path: Path, default: Any) -> Any:
    if not path.is_file():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def git_sha(repo: Path) -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return out.strip() or None
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def host_info() -> dict[str, Any]:
    cpus = os.cpu_count()
    mem = None
    try:
        if Path("/proc/meminfo").is_file():
            for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
                if line.startswith("MemTotal:"):
                    mem = int(line.split()[1]) * 1024
                    break
        elif sys.platform == "darwin":
            out = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)
            mem = int(out.strip())
    except (OSError, ValueError, subprocess.CalledProcessError):
        pass
    return {
        "hostname": platform.node(),
        "system": platform.system(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_count": cpus,
        "mem_bytes": mem,
    }


def cmd_init(args: argparse.Namespace) -> int:
    d = Path(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    (d / "steps.jsonl").touch(exist_ok=True)
    repo = d.resolve()
    for _ in range(6):
        if (repo / ".git").exists() or (repo / "run.sh").exists():
            break
        repo = repo.parent
    extra = json.loads(args.extra) if args.extra else {}
    meta = {
        "run_id": d.name,
        "started_at": utc_now(),
        "finished_at": None,
        "status": "running",
        "label": args.label or None,
        "git_sha": git_sha(repo),
        "host": host_info(),
        "env": {
            k: os.environ.get(k)
            for k in (
                "DB_HOST",
                "DB_PORT",
                "DB_NAME",
                "DB_USER",
                "CRS",
                "BBOX",
                "OSM2PGSQL_NUMBER_PROCESSES",
                "PERF_AUDIT_LABEL",
            )
            if os.environ.get(k)
        },
        "extra": extra,
        "total_duration_ms": None,
    }
    write_json(d / "meta.json", meta)
    return 0


def cmd_step(args: argparse.Namespace) -> int:
    d = Path(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    detail = parse_detail(args.detail)
    duration_ms = max(0, int(args.end_ms) - int(args.start_ms))
    row = {
        "ts": utc_now(),
        "event": "step",
        "name": args.name,
        "phase": args.phase,
        "start_ms": int(args.start_ms),
        "end_ms": int(args.end_ms),
        "duration_ms": duration_ms,
        "status": args.status,
        "exit_code": int(args.exit_code),
        "detail": detail,
    }
    with (d / "steps.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return 0


def cmd_finish(args: argparse.Namespace) -> int:
    d = Path(args.dir)
    meta_path = d / "meta.json"
    meta = read_json(meta_path, {})
    meta["finished_at"] = utc_now()
    meta["status"] = args.status
    steps = []
    steps_path = d / "steps.jsonl"
    if steps_path.is_file():
        for line in steps_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                steps.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    timed = [s for s in steps if s.get("status") != "note"]
    if timed:
        meta["total_duration_ms"] = sum(int(s.get("duration_ms") or 0) for s in timed)
        meta["step_count"] = len(timed)
    write_json(meta_path, meta)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    init = sub.add_parser("init")
    init.add_argument("--dir", required=True)
    init.add_argument("--label", default="")
    init.add_argument("--extra", default="{}")
    init.set_defaults(func=cmd_init)

    step = sub.add_parser("step")
    step.add_argument("--dir", required=True)
    step.add_argument("--name", required=True)
    step.add_argument("--phase", required=True)
    step.add_argument("--start-ms", required=True)
    step.add_argument("--end-ms", required=True)
    step.add_argument("--status", required=True)
    step.add_argument("--detail", default="{}")
    step.add_argument("--exit-code", default="0")
    step.set_defaults(func=cmd_step)

    finish = sub.add_parser("finish")
    finish.add_argument("--dir", required=True)
    finish.add_argument("--status", default="ok")
    finish.set_defaults(func=cmd_finish)

    args = p.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
