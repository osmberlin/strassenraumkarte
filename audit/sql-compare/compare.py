#!/usr/bin/env python3
"""
Compare two SQL fingerprint snapshots.

Exit 0 if equal, 1 if differences, 2 on usage errors.

Usage:
  ./audit/sql-compare/compare.py audit/sql-compare/reference/baseline.json candidate.json
  ./audit/sql-compare/compare.py --group building reference.json candidate.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def index_tables(group: dict) -> dict[str, dict]:
    out = {}
    for t in group.get("tables") or []:
        key = t["table"]
        if t.get("where"):
            key = f"{t['table']}|{t['where']}"
        out[key] = t
    return out


def compare(ref: dict, cand: dict, groups: list[str] | None) -> list[dict[str, Any]]:
    diffs: list[dict[str, Any]] = []
    ref_groups = ref.get("groups") or {}
    cand_groups = cand.get("groups") or {}
    names = groups or sorted(set(ref_groups) | set(cand_groups))
    for gname in names:
        if gname not in ref_groups:
            diffs.append({"group": gname, "issue": "missing_in_reference"})
            continue
        if gname not in cand_groups:
            diffs.append({"group": gname, "issue": "missing_in_candidate"})
            continue
        rt = index_tables(ref_groups[gname])
        ct = index_tables(cand_groups[gname])
        for key in sorted(set(rt) | set(ct)):
            if key not in rt:
                diffs.append({"group": gname, "table": key, "issue": "extra_in_candidate"})
                continue
            if key not in ct:
                diffs.append({"group": gname, "table": key, "issue": "missing_in_candidate"})
                continue
            a, b = rt[key], ct[key]
            if a.get("count") != b.get("count") or a.get("digest") != b.get("digest"):
                diffs.append(
                    {
                        "group": gname,
                        "table": a.get("table"),
                        "where": a.get("where"),
                        "issue": "fingerprint_mismatch",
                        "ref_count": a.get("count"),
                        "cand_count": b.get("count"),
                        "ref_digest": a.get("digest"),
                        "cand_digest": b.get("digest"),
                    }
                )
    return diffs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("reference", type=Path)
    ap.add_argument("candidate", type=Path)
    ap.add_argument("--group", action="append", dest="groups")
    ap.add_argument("--json", action="store_true", help="Machine-readable diffs only")
    args = ap.parse_args()

    if not args.reference.exists() or not args.candidate.exists():
        print("reference and candidate JSON paths must exist", file=sys.stderr)
        return 2

    diffs = compare(load(args.reference), load(args.candidate), args.groups)
    if args.json:
        json.dump({"ok": not diffs, "diffs": diffs}, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        if not diffs:
            print("OK — fingerprints match")
        else:
            print(f"DIFF — {len(diffs)} mismatch(es):")
            for d in diffs:
                print(f"  - {json.dumps(d, ensure_ascii=False)}")
    return 0 if not diffs else 1


if __name__ == "__main__":
    raise SystemExit(main())
