#!/usr/bin/env python3
"""
Snapshot SQL fingerprints for Straßenraumkarte processing tables.

Usage:
  ./audit/sql-compare/snapshot.py --out audit/sql-compare/reference/baseline.json
  ./audit/sql-compare/snapshot.py --group building --out /tmp/building.json
  ./audit/sql-compare/snapshot.py --list-groups

Connects via env DB_* (see data/db_config.sh). Prefer docker:
  ./audit/sql-compare/psql.sh -c 'select 1'
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = Path(__file__).resolve().parent / "tables.json"
PSQL_SH = Path(__file__).resolve().parent / "psql.sh"


def load_config(path: Path) -> dict:
    # Prefer sibling .json (no PyYAML required); else YAML if available.
    if path.suffix.lower() in {".yaml", ".yml"}:
        json_sib = path.with_suffix(".json")
        if json_sib.exists():
            return json.loads(json_sib.read_text())
        if yaml is None:
            raise SystemExit(
                f"Missing {json_sib} and PyYAML is not installed to read {path}."
            )
        return yaml.safe_load(path.read_text())
    return json.loads(path.read_text())


def quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def build_fingerprint_sql(table: dict, grid_m: float) -> str:
    name = table["name"]
    id_cols = table.get("id") or []
    attr_cols = table.get("attrs") or []
    geom = table.get("geom")
    where = table.get("where")

    parts: list[str] = []
    for c in id_cols + attr_cols:
        parts.append(f"coalesce({quote_ident(c)}::text, '')")

    if geom:
        g = quote_ident(geom)
        if grid_m and grid_m > 0:
            geom_expr = f"ST_Normalize(ST_SnapToGrid({g}, {grid_m}))"
        else:
            geom_expr = f"ST_Normalize({g})"
        parts.append(
            f"coalesce(md5(ST_AsEWKB({geom_expr})), '')"
        )

    concat = " || '|' || ".join(parts) if parts else "''"
    row_hash = f"md5({concat})"

    where_sql = f"WHERE ({where})" if where else ""
    # Filter null/empty geoms when hashing geometry
    if geom:
        g = quote_ident(geom)
        geom_ok = f"{g} IS NOT NULL AND NOT ST_IsEmpty({g})"
        where_sql = f"WHERE ({where}) AND ({geom_ok})" if where else f"WHERE {geom_ok}"

    return f"""
SELECT json_build_object(
  'table', '{name}',
  'count', count(*)::bigint,
  'digest', coalesce(md5(string_agg(h, '' ORDER BY h)), md5('')),
  'where', {'null' if not where else "'" + where.replace("'", "''") + "'"}
)
FROM (
  SELECT {row_hash} AS h
  FROM {quote_ident(name)}
  {where_sql}
) s
""".strip()


def run_psql_json(sql: str) -> dict:
    env = os.environ.copy()
    cmd = [str(PSQL_SH), "-v", "ON_ERROR_STOP=1", "-t", "-A", "-c", sql]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=str(ROOT))
    if proc.returncode != 0:
        raise RuntimeError(
            f"psql failed ({proc.returncode}):\n{proc.stderr or proc.stdout}\nSQL:\n{sql}"
        )
    out = proc.stdout.strip()
    if not out:
        raise RuntimeError(f"Empty psql output for SQL:\n{sql}")
    # -t -A may still wrap; take last non-empty line
    line = [ln for ln in out.splitlines() if ln.strip()][-1]
    return json.loads(line)


def snapshot(config: dict, groups: list[str] | None) -> dict:
    grid_m = float(config.get("grid_m") or 0)
    selected = groups or list(config["groups"].keys())
    result = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "grid_m": grid_m,
        "groups": {},
    }
    for gname in selected:
        if gname not in config["groups"]:
            raise SystemExit(f"Unknown group: {gname}")
        gdef = config["groups"][gname]
        tables_out = []
        t0 = time.time()
        for table in gdef["tables"]:
            sql = build_fingerprint_sql(table, grid_m)
            try:
                fp = run_psql_json(sql)
            except RuntimeError as exc:
                # where clause may reference missing cols — retry without where once
                if table.get("where"):
                    t2 = dict(table)
                    t2.pop("where", None)
                    fp = run_psql_json(build_fingerprint_sql(t2, grid_m))
                    fp["where_fallback"] = True
                    fp["error"] = str(exc)[:200]
                else:
                    raise
            tables_out.append(fp)
        result["groups"][gname] = {
            "description": gdef.get("description", ""),
            "duration_ms": int((time.time() - t0) * 1000),
            "tables": tables_out,
        }
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--out", type=Path, help="Write JSON snapshot")
    ap.add_argument("--group", action="append", dest="groups", help="Limit to group(s)")
    ap.add_argument("--list-groups", action="store_true")
    args = ap.parse_args()

    config = load_config(args.config)
    if args.list_groups:
        for name, g in config["groups"].items():
            print(f"{name}: {g.get('description', '')}")
        return 0

    snap = snapshot(config, args.groups)
    text = json.dumps(snap, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
        print(f"Wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
