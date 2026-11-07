"""Hand-built SVG mockups for exploration 03 (bold-line print).

Not a renderer: one made-up perimeter block between three streets and a canal,
drawn three ways so the folding options can be compared.

    python3 docs/design-research/03-bold-line-print/mockups/make_mockups.py
"""
import random
from pathlib import Path

OUT = Path(__file__).parent
PAPER, INK, ACCENT = "#F3F0E8", "#141414", "#E0442A"
W = 4.0  # main stroke (z19 in the briefing's scale)
F = 2.0  # fine stroke
CW, CH = 760, 620

# Block: outer ring, courtyard, ridge ring (hipped skeleton of a uniform ring)
OUTER = (80, 120, 620, 440)
COURT = (200, 220, 500, 340)
RIDGE = (140, 170, 560, 390)
# houses along each wing: (length along the edge, levels)
HOUSES = {
    "n": [(110, 5), (90, 5), (120, 6), (90, 4), (130, 5)],
    "s": [(140, 5), (100, 4), (100, 5), (90, 5), (110, 6)],
    "w": [(160, 5), (160, 4)],
    "e": [(110, 5), (90, 6), (120, 5)],
}
FLOOR = 15.0  # px per storey on the folded facade (compressed so 6 storeys fit the wing depth)


def svg_open(title):
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CW} {CH}" width="{CW}" height="{CH}">',
        f"<title>{title}</title>",
        f'<rect width="{CW}" height="{CH}" fill="{PAPER}"/>',
        "<defs>",
        *[
            f'<pattern id="h{p}" width="{p}" height="{p}" patternUnits="userSpaceOnUse">'
            f'<rect width="{p}" height="{W}" fill="{INK}"/></pattern>'
            for p in (8, 12, 16)
        ],
        *[
            f'<pattern id="v{p}" width="{p}" height="{p}" patternUnits="userSpaceOnUse">'
            f'<rect width="{W}" height="{p}" fill="{INK}"/></pattern>'
            for p in (8, 12, 16)
        ],
        "</defs>",
    ]


def poly(pts, fill="none", stroke=INK, sw=W, extra=""):
    d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    return f'<polygon points="{d}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="miter" {extra}/>'


def line(x1, y1, x2, y2, sw=W, stroke=INK, cap="butt"):
    return f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}"/>'


def rect_pts(r):
    x0, y0, x1, y1 = r
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def facets():
    """Outer (street) and inner (courtyard) facets per side, mitred at the corners."""
    o, r, c = rect_pts(OUTER), rect_pts(RIDGE), rect_pts(COURT)
    sides = {"n": (0, 1), "e": (1, 2), "s": (2, 3), "w": (3, 0)}
    outer = {k: [o[a], o[b], r[b], r[a]] for k, (a, b) in sides.items()}
    inner = {k: [c[a], c[b], r[b], r[a]] for k, (a, b) in sides.items()}
    return outer, inner


def streets(out, trees_upright=False, tree_colour=INK):
    # carriageways: north (horizontal), west and east (vertical), south quay street; kerbs as heavy lines
    out.append(line(0, 52, CW, 52))
    for x0, x1 in ((0, 20), (64, 636), (680, CW)):
        out.append(line(x0, 96, x1, 96))
        out.append(line(x0, 460, x1, 460))
    for x in (20, 64, 636, 680):
        out.append(line(x, 96, x, 460))
    # centre line: broken, world-anchored lengths
    rnd = random.Random(3)
    x = 8
    while x < CW:
        n = rnd.choice([18, 26, 40])
        out.append(line(x, 74, min(x + n, CW), 74, F))
        x += n + rnd.choice([10, 14])
    out.append(line(0, 500, CW, 500))
    # sidewalk edge of block = building line, drawn with the block
    # trees on the north sidewalk
    for tx in (120, 230, 340, 450, 560):
        if trees_upright:
            out.append(line(tx, 110, tx, 92, W, tree_colour))
            out.append(f'<circle cx="{tx}" cy="80" r="12" fill="{PAPER}" stroke="{tree_colour}" stroke-width="{W}"/>')
        else:
            out.append(f'<circle cx="{tx}" cy="108" r="9" fill="{PAPER}" stroke="{tree_colour}" stroke-width="{W}"/>')
            out.append(f'<circle cx="{tx}" cy="108" r="1.8" fill="{tree_colour}"/>')


def canal(out):
    # horizontal stripes, stroke = gap, broken into world-anchored dashes
    rnd = random.Random(7)
    y = 512
    while y < CH - 8:
        x = rnd.choice([0, 6, 18])
        while x < CW:
            n = rnd.choice([60, 90, 140, 220, 320])
            out.append(line(x, y, min(x + n, CW), y))
            x += n + rnd.choice([8, 8, 12, 30])
        y += 2 * W
    # quay bollards
    for bx in range(30, CW, 70):
        out.append(line(bx, 500, bx, 492, W))


def party_walls(side):
    """Positions of the house boundaries along one side, in local u (0 = start corner)."""
    us, u = [], 0
    for length, lv in HOUSES[side]:
        us.append((u, u + length, lv))
        u += length
    return us


def side_frame(side):
    """Origin, along-edge unit vector, into-block unit vector, edge length."""
    x0, y0, x1, y1 = OUTER
    return {
        "n": ((x0, y0), (1, 0), (0, 1), x1 - x0),
        "s": ((x1, y1), (-1, 0), (0, -1), x1 - x0),
        "w": ((x0, y1), (0, -1), (1, 0), y1 - y0),
        "e": ((x1, y0), (0, 1), (-1, 0), y1 - y0),
    }[side]


def to_xy(side, u, v):
    (ox, oy), (ax, ay), (bx, by), _ = side_frame(side)
    return ox + ax * u + bx * v, oy + ay * u + by * v


def plan(out, tree_colour):
    outer, inner = facets()
    # tone by aspect: north-facing dense, east/west medium, south-facing blank
    tone = {"n": "url(#h8)", "s": None, "e": "url(#v12)", "w": "url(#v16)"}
    inner_tone = {"n": None, "s": "url(#h8)", "e": "url(#v16)", "w": "url(#v12)"}
    for k, pts in outer.items():
        if tone[k]:
            out.append(poly(pts, fill=tone[k], stroke="none"))
    for k, pts in inner.items():
        if inner_tone[k]:
            out.append(poly(pts, fill=inner_tone[k], stroke="none"))
    # ridges and hips
    rp = rect_pts(RIDGE)
    out.append(poly(rp))
    for (ax, ay), (bx, by) in zip(rect_pts(OUTER), rp):
        out.append(line(ax, ay, bx, by))
    for (ax, ay), (bx, by) in zip(rect_pts(COURT), rp):
        out.append(line(ax, ay, bx, by))
    # party walls as short fine ticks from the street edge
    for side in "nsew":
        for u0, _, _ in party_walls(side)[1:]:
            a = to_xy(side, u0, 0)
            b = to_xy(side, u0, 18)
            out.append(line(*a, *b, F))
    out.append(poly(rect_pts(OUTER), sw=W * 1.5))
    out.append(poly(rect_pts(COURT)))
    # courtyard tree
    out.append(f'<circle cx="350" cy="280" r="26" fill="{PAPER}" stroke="{tree_colour}" stroke-width="{W}"/>')
    out.append(f'<circle cx="350" cy="280" r="2.5" fill="{tree_colour}"/>')


def facade(out, side, clip_id):
    """A folded facade in the outer facet: base on the street edge, storeys going into the block."""
    out.append(f'<g clip-path="url(#{clip_id})">')
    for u0, u1, lv in party_walls(side):
        h = lv * FLOOR
        # eave line (stepped where heights differ) and party walls
        out.append(line(*to_xy(side, u0, h), *to_xy(side, u1, h)))
        out.append(line(*to_xy(side, u0, 0), *to_xy(side, u0, h)))
        # roof strip beyond the eave: stripes parallel to the eave
        v = h + 2 * W
        while v < 120:
            out.append(line(*to_xy(side, u0 + 2, v), *to_xy(side, u1 - 2, v), W))
            v += 3 * W
        # window axes every ~30 px, a pair of vertical bars per window
        n_ax = max(1, round((u1 - u0) / 30))
        step = (u1 - u0) / n_ax
        door = n_ax // 2
        for i in range(n_ax):
            cu = u0 + step * (i + 0.5)
            for f in range(lv):
                vb = f * FLOOR + 4
                vt = vb + FLOOR - 7
                if f == 0 and i == door:
                    # door: arch on the ground floor
                    pts = [to_xy(side, cu - 6, 0), to_xy(side, cu - 6, vt - 4), to_xy(side, cu, vt), to_xy(side, cu + 6, vt - 4), to_xy(side, cu + 6, 0)]
                    d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
                    out.append(f'<polyline points="{d}" fill="none" stroke="{INK}" stroke-width="{F}"/>')
                    continue
                for du in (-4, 4):
                    out.append(line(*to_xy(side, cu + du, vb), *to_xy(side, cu + du, vt), W))
        # floor line above the ground floor
        out.append(line(*to_xy(side, u0, FLOOR), *to_xy(side, u1, FLOOR), F))
    out.append("</g>")


def fold_outward(out, tree_colour):
    outer, inner = facets()
    o, c = rect_pts(OUTER), rect_pts(COURT)
    wings = {k: [o[a], o[b], c[b], c[a]] for k, (a, b) in {"n": (0, 1), "e": (1, 2), "s": (2, 3), "w": (3, 0)}.items()}
    out.append("<defs>")
    for k, pts in wings.items():
        d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        out.append(f'<clipPath id="c{k}"><polygon points="{d}"/></clipPath>')
    out.append("</defs>")
    for k in "nsew":
        facade(out, k, f"c{k}")
    # mitre at the corners: the hip + valley of the straight skeleton
    for (ax, ay), (bx, by) in zip(rect_pts(OUTER), rect_pts(COURT)):
        out.append(line(ax, ay, bx, by))
    out.append(poly(rect_pts(OUTER), sw=W * 1.5))
    out.append(poly(rect_pts(COURT)))
    out.append(line(350, 300, 350, 282, W, tree_colour))
    out.append(f'<circle cx="350" cy="266" r="18" fill="{PAPER}" stroke="{tree_colour}" stroke-width="{W}"/>')


def fold_south(out, tree_colour):
    """Classic oblique: the south facade hangs down over the quay, the rest is roof in plan."""
    outer, inner = facets()
    tone = {"n": "url(#h8)", "e": "url(#v12)", "w": "url(#v16)"}
    for k, pts in outer.items():
        if k in tone:
            out.append(poly(pts, fill=tone[k], stroke="none"))
    out.append(poly(inner["s"], fill="url(#h8)", stroke="none"))
    rp = rect_pts(RIDGE)
    for (ax, ay), (bx, by) in zip(rect_pts(OUTER), rp):
        out.append(line(ax, ay, bx, by))
    for (ax, ay), (bx, by) in zip(rect_pts(COURT), rp):
        out.append(line(ax, ay, bx, by))
    out.append(poly(rp))
    out.append(poly(rect_pts(OUTER), sw=W * 1.5))
    out.append(poly(rect_pts(COURT)))
    # facade hung below the south edge (local frame: base at y = 440 + h, rising to 440)
    x0, _, x1, y1 = OUTER
    u = x0
    for length, lv in reversed(HOUSES["s"]):
        h = lv * FLOOR * 0.9
        out.append(f'<rect x="{u:.1f}" y="{y1:.1f}" width="{length:.1f}" height="{h:.1f}" fill="{PAPER}" stroke="{INK}" stroke-width="{W}"/>')
        n_ax = max(1, round(length / 30))
        step = length / n_ax
        for i in range(n_ax):
            cx = u + step * (i + 0.5)
            for f in range(lv):
                fy = y1 + h - (f + 1) * FLOOR * 0.9 + 2
                out.append(line(cx - 4, fy, cx - 4, fy + FLOOR * 0.9 - 5, W))
                out.append(line(cx + 4, fy, cx + 4, fy + FLOOR * 0.9 - 5, W))
        u += length
    out.append(f'<circle cx="350" cy="280" r="26" fill="{PAPER}" stroke="{tree_colour}" stroke-width="{W}"/>')


def label(out, text):
    out.append(f'<rect x="250" y="8" width="260" height="34" fill="{PAPER}" stroke="{INK}" stroke-width="{W}"/>')
    out.append(
        f'<text x="380" y="31" text-anchor="middle" font-family="Futura, Avenir Next, Helvetica, sans-serif" '
        f'font-weight="700" font-size="15" letter-spacing="4" fill="{INK}">{text}</text>'
    )


def write(name, title, body):
    out = svg_open(title)
    body(out)
    out.append("</svg>")
    (OUT / name).write_text("\n".join(out) + "\n")


def mock_a(out):
    streets(out, tree_colour=ACCENT)
    canal(out)
    plan(out, ACCENT)
    label(out, "• PLAN •")


def mock_b(out):
    streets(out, trees_upright=True)
    canal(out)
    fold_outward(out, INK)
    label(out, "• ABWICKLUNG •")


def mock_c(out):
    streets(out, trees_upright=True)
    canal(out)
    fold_south(out, INK)
    label(out, "• SÜDFASSADE •")


write("a-plan.svg", "03 bold-line: (a) plan view, roof facets toned by aspect, trees in the accent colour", mock_a)
write("b-fold-outward.svg", "03 bold-line: (b) facades folded away from the street into the roof zone", mock_b)
write("c-fold-south.svg", "03 bold-line: (b, alternative) south facades hung over the street", mock_c)
