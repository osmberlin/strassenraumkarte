#!/usr/bin/env python3
"""Render a legend sheet for a design-research style: one real map sample per feature class.

    python3 legend.py la|ink [--out legend.jpg] [--env SRK_ACCENT=bench] [--columns 6]

For every legend item a representative feature near the Schillerkiez is looked up in PostGIS
(deep inside an area, the middle of a line, a solitary tree …), the tiles around it are rendered
with `srk-render --layers <style>` and a square swatch is cut out around the feature. Swatches and
labels are laid out on a sheet in the style's paper and type.

Default output: ../01-landscape-architecture/legend.jpg (la) or ../02-fantasy-ink-map/legend.jpg (ink).
`map_sheet.py --legend <file>` puts a legend into a map sheet (use `--columns 8` for a wide strip).

Needs: psql on PATH, the DB on DB_PORT (5433) and a release build of srk-render (or SRK_BIN).
"""
import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from map_sheet import font  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../../.."))
ORIGIN = 20037508.342789244
SWATCH = 180

# Scene area (search centre) and the extent of the processed DB used for the scenes.
CENTRE = "ST_Transform(ST_SetSRID(ST_Point(13.4250, 52.4760), 4326), 3857)"
EXTENT = "ST_Transform(ST_MakeEnvelope(13.4110, 52.4688, 13.4510, 52.4828, 4326), 3857)"
SOLITARY = "NOT EXISTS (SELECT 1 FROM tree t2 WHERE t2.osm_id <> t.osm_id AND ST_DWithin(t2.geom, t.geom, 14))"
IN_ROW = "(SELECT count(*) FROM tree t2 WHERE ST_DWithin(t2.geom, t.geom, 30)) >= 6"
HOUSES = "('house', 'detached', 'semidetached_house', 'bungalow')"
GREEN = "EXISTS (SELECT 1 FROM landuse l WHERE l.class IN ('grass', 'park', 'playground', 'meadow') AND ST_DWithin(l.geom, {a}.geom, 2))"

# key, label, kind, table, where, zoom, size (area: min inscribed radius in m; line: min length)
ITEMS = [
    ("lawn", "Rasen", "area", "landuse", "class = 'grass'", 19, 30),
    ("scrub", "Gebüsch", "area", "landuse", "class = 'scrub'", 19, 18),
    ("flowerbed", "Beet / Baumscheibe", "area", "landuse", "class IN ('flowerbed', 'tree_pit')", 19, 4),
    ("forest", "Wald", "area", "landuse", "class IN ('forest', 'wood')", 18, 60),
    ("water", "Wasser", "area", "water_body", "true", 18, 40),
    ("sand", "Sand / Fallschutz", "area", "landuse", "class IN ('sand', 'woodchips')", 19, 6),
    ("playground", "Spielplatz", "area", "playground_polygon", "true", 19, 14),
    ("pitch", "Sportplatz", "area", "pitch", "true", 18, 20),
    ("cemetery", "Friedhof", "area", "landuse", "class = 'cemetery'", 18, 60),
    ("allotments", "Kleingärten", "area", "landuse", "class = 'allotments'", 18, 50),
    ("parking", "Parkplatz", "area", "landuse", "class = 'parking'", 19, 14),
    ("block", "Wohnblock", "area", "building", "building IN ('apartments', 'residential') AND \"building:part\" IS NULL", 19, 10),
    ("house", "Kleine Häuser", "area", "building h", f"building IN {HOUSES} AND ST_Area(geom) < 400 AND "
     f"(SELECT count(*) FROM building h2 WHERE h2.building IN {HOUSES} AND ST_DWithin(h2.geom, h.geom, 40)) >= 4", 18, 3),
    ("church", "Kirche (Landmarke)", "area", "building", "building IN ('church', 'chapel')", 18, 6),
    ("tree", "Laubbaum (solitär)", "point", "tree t", f"leaf_type = 'broadleaved' AND {SOLITARY}", 19, 0),
    ("conifer", "Nadelbaum", "point", "tree t", f"leaf_type = 'needleleaved' AND {SOLITARY}", 19, 0),
    ("treerow", "Straßenbäume", "point", "tree t", IN_ROW, 18, 0),
    ("bench", "Bank", "point", "feature_node f", "class = 'bench' AND " + GREEN.format(a="f"), 20, 0),
    ("hedge", "Hecke", "line", "barrier_way", "barrier = 'hedge'", 19, 40),
    ("fence", "Zaun", "line", "barrier_way b", "barrier = 'fence' AND " + GREEN.format(a="b"), 19, 40),
    ("wall", "Mauer", "line", "barrier_way b", "barrier IN ('wall', 'retaining_wall') AND " + GREEN.format(a="b"), 19, 30),
    ("embankment", "Böschung", "line", "landscape_way", "class = 'embankment'", 19, 40),
    ("rail", "Eisenbahn", "line", "railway_way", "railway = 'rail' AND tunnel IS NULL", 18, 120),
]

STYLE = {
    "la": dict(title="Legende · Landschaftsarchitektur", paper=(247, 246, 242), ink=(78, 77, 70), muted=(150, 148, 140),
               kind="sans", out="01-landscape-architecture/legend.jpg"),
    "ink": dict(title="Legende · Tuschekarte", paper=(241, 231, 207), ink=(43, 38, 32), muted=(120, 108, 90),
                kind="serif", out="02-fantasy-ink-map/legend.jpg"),
}


def sql_for(kind, table, where, size):
    if kind == "area":
        return f"""
          SELECT ST_X(c), ST_Y(c) FROM (
            SELECT (ST_MaximumInscribedCircle(geom)).center AS c, (ST_MaximumInscribedCircle(geom)).radius AS r
            FROM {table} WHERE {where} AND ST_Intersects(geom, {EXTENT})) s
          ORDER BY (r >= {size}) DESC, CASE WHEN r >= {size} THEN c <-> {CENTRE} ELSE -r END LIMIT 1"""
    if kind == "line":
        return f"""
          SELECT ST_X(p), ST_Y(p) FROM (
            SELECT ST_LineInterpolatePoint(g, 0.5) AS p, ST_Length(g) AS len FROM (
              SELECT (ST_Dump(ST_LineMerge(geom))).geom AS g FROM {table} WHERE {where} AND ST_Intersects(geom, {EXTENT})) d
            WHERE GeometryType(g) = 'LINESTRING') s
          ORDER BY (len >= {size}) DESC, p <-> {CENTRE} LIMIT 1"""
    return f"""
      SELECT ST_X(geom), ST_Y(geom) FROM {table}
      WHERE {where} AND ST_Intersects(geom, {EXTENT}) ORDER BY geom <-> {CENTRE} LIMIT 1"""


def lookup(sql):
    env = {**os.environ, "PGPASSWORD": os.environ.get("PGPASSWORD", "postgres")}
    cmd = ["psql", "-h", os.environ.get("DB_HOST", "localhost"), "-p", os.environ.get("DB_PORT", "5433"),
           "-U", os.environ.get("DB_USER", "postgres"), "-d", os.environ.get("DB_NAME", "strassenraumkarte"),
           "-At", "-v", "ON_ERROR_STOP=1", "-c", sql]
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print("  sql error:", r.stderr.strip().splitlines()[-1] if r.stderr.strip() else r.returncode, file=sys.stderr)
        return None
    line = r.stdout.strip()
    return tuple(map(float, line.split("|"))) if line else None


def world_px(x, y, z):
    n = 256 * 2 ** z
    return (x + ORIGIN) / (2 * ORIGIN) * n, (ORIGIN - y) / (2 * ORIGIN) * n


def window(px, py):
    x0, y0 = int(round(px - SWATCH / 2)), int(round(py - SWATCH / 2))
    return x0, y0, x0 + SWATCH, y0 + SWATCH


def wrap(draw, text, fnt, width):
    lines, cur = [], ""
    for word in text.split():
        t = (cur + " " + word).strip()
        if draw.textlength(t, font=fnt) <= width or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = word
    return lines + [cur]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("style", choices=STYLE)
    ap.add_argument("--out")
    ap.add_argument("--env", action="append", default=[], metavar="KEY=VALUE", help="variant switch for srk-render (repeatable)")
    ap.add_argument("--columns", type=int, default=6)
    ap.add_argument("--only", help="comma-separated item keys (default: all)")
    ap.add_argument("--title")
    ap.add_argument("--keep", metavar="DIR", help="render tiles into DIR and keep them (default: temp dir, deleted)")
    a = ap.parse_args()
    st = dict(STYLE[a.style])
    if a.style == "ink" and "SRK_INK_PAPER=white" in a.env:
        st.update(paper=(251, 250, 246), ink=(21, 21, 21), muted=(120, 120, 120))
    out = a.out or os.path.join(HERE, "..", st["out"])
    items = [i for i in ITEMS if not a.only or i[0] in a.only.split(",")]

    # 1. find a sample location for every item
    found = []
    for key, label, kind, table, where, z, size in items:
        p = lookup(sql_for(kind, table, where, size))
        print(f"  {key:11s} {'–' if p is None else f'{p[0]:.0f},{p[1]:.0f} z{z}'}")
        if p:
            found.append((key, label, z, world_px(p[0], p[1], z)))
    if not found:
        sys.exit("no samples found — is the DB up (DB_PORT=5433)?")

    # 2. render every tile the swatches touch, in one srk-render call
    tiles = set()
    for _, _, z, (px, py) in found:
        x0, y0, x1, y1 = window(px, py)
        for tx in range(x0 // 256, (x1 - 1) // 256 + 1):
            for ty in range(y0 // 256, (y1 - 1) // 256 + 1):
                tiles.add(f"{z}/{tx}/{ty}")
    tmp = a.keep or tempfile.mkdtemp(prefix="srk-legend-")
    binary = os.environ.get("SRK_BIN", os.path.join(ROOT, "rust/srk-render/target/release/srk-render"))
    env = {**os.environ, "DB_PORT": os.environ.get("DB_PORT", "5433"), "PGPASSWORD": os.environ.get("PGPASSWORD", "postgres")}
    for kv in a.env:
        k, v = kv.split("=", 1)
        env[k] = v
    print(f"  rendering {len(tiles)} tiles with --layers {a.style} {' '.join(a.env)}")
    subprocess.run([binary, "--tiles", ",".join(sorted(tiles)), "--layers", a.style, "--out", tmp, "--format", "png",
                    "--gutter", "1", "--workers", "4", "--quiet"], env=env, cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def swatch(z, px, py):
        x0, y0, x1, y1 = window(px, py)
        im = Image.new("RGB", (SWATCH, SWATCH), st["paper"])
        for tx in range(x0 // 256, (x1 - 1) // 256 + 1):
            for ty in range(y0 // 256, (y1 - 1) // 256 + 1):
                f = f"{tmp}/{z}/{tx}/{ty}.png"
                if os.path.exists(f):
                    im.paste(Image.open(f).convert("RGB"), (tx * 256 - x0, ty * 256 - y0))
        return im

    # 3. lay out the sheet
    cols = min(a.columns, len(found))
    rows = math.ceil(len(found) / cols)
    gap, label_h, margin, head = 26, 58, 48, 96
    W = margin * 2 + cols * SWATCH + (cols - 1) * gap
    H = margin + head + rows * (SWATCH + label_h) + (rows - 1) * gap // 2 + margin // 2
    sheet = Image.new("RGB", (W, H), st["paper"])
    d = ImageDraw.Draw(sheet)
    title = a.title or st["title"] + (" · " + ", ".join(a.env) if a.env else "")
    d.text((margin, margin + 18), title, font=font(st["kind"], 40, 2 if st["kind"] == "sans" else 0), fill=st["ink"], anchor="lm")
    d.line([margin, margin + head - 30, W - margin, margin + head - 30], fill=st["muted"], width=1)
    f_label, f_zoom = font(st["kind"], 21), font(st["kind"], 15)
    for i, (key, label, z, (px, py)) in enumerate(found):
        r, c = divmod(i, cols)
        x = margin + c * (SWATCH + gap)
        y = margin + head + r * (SWATCH + label_h + gap // 2)
        sheet.paste(swatch(z, px, py), (x, y))
        d.rectangle([x - 1, y - 1, x + SWATCH, y + SWATCH], outline=st["ink"], width=1)
        ty = y + SWATCH + 8
        for line in wrap(d, label, f_label, SWATCH)[:2]:
            d.text((x, ty), line, font=f_label, fill=st["ink"])
            ty += 24
        tw = d.textlength(f"z{z}", font=f_zoom)
        d.rectangle([x + SWATCH - tw - 9, y, x + SWATCH - 1, y + 19], fill=st["paper"])
        d.text((x + SWATCH - 5, y + 10), f"z{z}", font=f_zoom, fill=st["muted"], anchor="rm")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    sheet.save(out, quality=84)
    if not a.keep:
        shutil.rmtree(tmp, ignore_errors=True)
    print(out, sheet.size)


if __name__ == "__main__":
    main()
