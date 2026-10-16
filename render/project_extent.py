#!/usr/bin/env python3
"""
Determine render extent when --bbox is omitted.

1) Prefer combined PostGIS layer extent (project CRS → reported as EPSG:4326)
2) Fallback: map canvas extent stored in the .qgz/.qgs project
"""

from __future__ import annotations

import os
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile


# Defaults match data/db_config.sh (override via env)
DB_NAME = os.environ.get("DB_NAME", "strassenraumkarte")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5433")
CRS = int(os.environ.get("CRS", "3857"))

CANDIDATE_TABLES = (
    "highway",
    "highway_area",
    "landuse",
    "building",
    "building_parts",
    "lanes",
)


def qgis_extent_string(xmin: float, ymin: float, xmax: float, ymax: float, epsg: int) -> str:
    return f"{xmin},{ymin},{xmax},{ymax} [EPSG:{epsg}]"


def extent_from_postgis() -> str | None:
    table_list = ",".join(f"'{t}'" for t in CANDIDATE_TABLES)
    sql = f"""
SELECT COALESCE(
  (
    SELECT string_agg(quote_ident(c.relname), ',')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname IN ({table_list})
  ),
  ''
);
"""
    env = os.environ.copy()
    if "PGPASSFILE" not in env and os.path.isfile(os.path.expanduser("~/.pgpass")):
        env["PGPASSFILE"] = os.path.expanduser("~/.pgpass")

    try:
        tables_raw = subprocess.check_output(
            [
                "psql",
                "-U", DB_USER,
                "-h", DB_HOST,
                "-p", DB_PORT,
                "-d", DB_NAME,
                "-At",
                "-c", sql,
            ],
            env=env,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    if not tables_raw:
        return None

    parts = []
    for table in tables_raw.split(","):
        parts.append(
            f"SELECT geom FROM {table} WHERE geom IS NOT NULL"
        )
    union_sql = " UNION ALL ".join(parts)
    extent_sql = f"""
SELECT
  ST_XMin(e), ST_XMax(e), ST_YMin(e), ST_YMax(e)
FROM (
  SELECT ST_Transform(ST_SetSRID(ST_Extent(geom), {CRS}), 4326) AS e
  FROM ({union_sql}) AS g
) AS x
WHERE e IS NOT NULL;
"""
    try:
        row = subprocess.check_output(
            [
                "psql",
                "-U", DB_USER,
                "-h", DB_HOST,
                "-p", DB_PORT,
                "-d", DB_NAME,
                "-At",
                "-F", ",",
                "-c", extent_sql,
            ],
            env=env,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except subprocess.CalledProcessError:
        return None

    if not row or row.count(",") != 3:
        return None
    xmin, xmax, ymin, ymax = (float(v) for v in row.split(","))
    return qgis_extent_string(xmin, ymin, xmax, ymax, 4326)


def read_qgs_xml(project_path: str) -> ET.Element:
    if project_path.lower().endswith(".qgz"):
        with zipfile.ZipFile(project_path) as zf:
            qgs_names = [n for n in zf.namelist() if n.lower().endswith(".qgs")]
            if not qgs_names:
                raise RuntimeError(f"No .qgs inside {project_path}")
            with zf.open(qgs_names[0]) as fh:
                return ET.parse(fh).getroot()
    return ET.parse(project_path).getroot()


def extent_from_mapcanvas(project_path: str) -> str | None:
    try:
        root = read_qgs_xml(project_path)
    except Exception:
        return None

    canvas = root.find("mapcanvas")
    if canvas is None:
        return None
    extent = canvas.find("extent")
    if extent is None:
        return None

    try:
        xmin = float(extent.findtext("xmin"))
        xmax = float(extent.findtext("xmax"))
        ymin = float(extent.findtext("ymin"))
        ymax = float(extent.findtext("ymax"))
    except (TypeError, ValueError):
        return None

    authid = canvas.findtext("destinationsrs/spatialrefsys/authid") or f"EPSG:{CRS}"
    try:
        epsg = int(authid.split(":")[-1])
    except ValueError:
        epsg = CRS

    # Reproject to 4326 with psql if needed (avoids extra Python GIS deps)
    if epsg == 4326:
        return qgis_extent_string(xmin, ymin, xmax, ymax, 4326)

    env = os.environ.copy()
    if "PGPASSFILE" not in env and os.path.isfile(os.path.expanduser("~/.pgpass")):
        env["PGPASSFILE"] = os.path.expanduser("~/.pgpass")

    transform_sql = f"""
SELECT
  ST_XMin(g), ST_XMax(g), ST_YMin(g), ST_YMax(g)
FROM (
  SELECT ST_Transform(
    ST_SetSRID(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}), {epsg}),
    4326
  ) AS g
) s;
"""
    try:
        row = subprocess.check_output(
            [
                "psql",
                "-U", DB_USER,
                "-h", DB_HOST,
                "-p", DB_PORT,
                "-d", DB_NAME,
                "-At",
                "-F", ",",
                "-c", transform_sql,
            ],
            env=env,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if row and row.count(",") == 3:
            x0, x1, y0, y1 = (float(v) for v in row.split(","))
            return qgis_extent_string(x0, y0, x1, y1, 4326)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    # Last resort: pass original project CRS to qgis_process
    return qgis_extent_string(xmin, ymin, xmax, ymax, epsg)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <project.qgz|qgs>", file=sys.stderr)
        return 1

    project_path = os.path.abspath(sys.argv[1])
    if not os.path.isfile(project_path):
        print(f"Project not found: {project_path}", file=sys.stderr)
        return 1

    extent = extent_from_postgis()
    if extent:
        print(extent)
        return 0

    extent = extent_from_mapcanvas(project_path)
    if extent:
        print(
            "Warning: using map canvas extent from project (PostGIS extent unavailable).",
            file=sys.stderr,
        )
        print(extent)
        return 0

    print("Could not determine project/data extent.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
