#!/usr/bin/env python3
"""Lay out a rendered map image as a printed sheet (frame, title, north arrow/compass, scale bar).

    python3 map_sheet.py ink|la <map.png> <out.jpg> --zoom 17 --lat 52.477 --title "Schillerkiez"
    python3 map_sheet.py ink <map.png> <out.jpg> --legend legend-wide.jpg   # legend band below the map

The legend comes from `legend.py` (`--columns 8` gives a wide strip that fits a band).

Layout only — the map itself comes from `srk-render`. Fonts: macOS system fonts.
"""
import argparse
import math

from PIL import Image, ImageDraw, ImageFont

FONTS = {
    "serif": "/System/Library/Fonts/Supplemental/Hoefler Text.ttc",
    "sans": "/System/Library/Fonts/Avenir Next.ttc",
}


def font(kind, size, index=0):
    try:
        return ImageFont.truetype(FONTS[kind], size, index=index)
    except OSError:
        return ImageFont.load_default()


def metres_per_px(zoom, lat):
    return 156543.03392 * math.cos(math.radians(lat)) / 2 ** zoom


def nice_length(max_m):
    for v in (1000, 500, 400, 300, 200, 100, 50, 20, 10):
        if v <= max_m:
            return v
    return 10


def spaced(draw, xy, text, fnt, fill, spacing, anchor="mm"):
    # letter-spaced text centred on xy
    widths = [draw.textlength(c, font=fnt) for c in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x = xy[0] - total / 2 if anchor == "mm" else xy[0]
    for c, w in zip(text, widths):
        draw.text((x, xy[1]), c, font=fnt, fill=fill, anchor="lm")
        x += w + spacing


def with_legend(m, legend):
    """Extend the map image by a band with the legend (scaled to at most 72 % of the map width).

    The right part of the band stays free: the ink sheet puts its scale bar there."""
    pad = 28
    s = min(1.0, 0.72 * m.width / legend.width)
    legend = legend.resize((round(legend.width * s), round(legend.height * s)), Image.LANCZOS)
    band = max(legend.height + 2 * pad, 170)
    out = Image.new("RGB", (m.width, m.height + band), legend.getpixel((2, 2)))
    out.paste(m, (0, 0))
    out.paste(legend, (pad, m.height + pad))
    ImageDraw.Draw(out).line([0, m.height, m.width, m.height], fill=(120, 116, 106), width=2)
    return out


def ink_sheet(m, args):
    ink, paper = ((21, 21, 21), (251, 250, 246)) if args.white else ((43, 38, 32), (241, 231, 207))
    pad, frame = 120, 34
    W, H = m.width + 2 * pad, m.height + 2 * pad + 40
    sheet = Image.new("RGB", (W, H), paper)
    sheet.paste(m, (pad, pad))
    d = ImageDraw.Draw(sheet)
    # double frame with a thin graduated band (old map border)
    for off, w in ((frame, 5), (frame + 14, 2), (pad - 6, 2)):
        d.rectangle([off, off, W - off, H - off], outline=ink, width=w)
    step = 28
    for i, x in enumerate(range(frame + 14, W - frame - 14, step)):
        if i % 2 == 0:
            d.rectangle([x, frame + 2, x + step, frame + 12], fill=ink)
            d.rectangle([x, H - frame - 12, x + step, H - frame - 2], fill=ink)
    for i, y in enumerate(range(frame + 14, H - frame - 14, step)):
        if i % 2 == 0:
            d.rectangle([frame + 2, y, frame + 12, y + step], fill=ink)
            d.rectangle([W - frame - 12, y, W - frame - 2, y + step], fill=ink)
    # cartouche: scroll-ish double box with title
    cw, ch = 760, 170
    cx, cy = pad + 40, pad + 40
    d.rectangle([cx - 10, cy - 10, cx + cw + 10, cy + ch + 10], fill=paper, outline=ink, width=3)
    d.rectangle([cx, cy, cx + cw, cy + ch], outline=ink, width=1)
    for sx in (cx - 10, cx + cw + 10):
        for sy in (cy - 10, cy + ch + 10):
            d.ellipse([sx - 14, sy - 14, sx + 14, sy + 14], fill=paper, outline=ink, width=2)
            d.ellipse([sx - 5, sy - 5, sx + 5, sy + 5], fill=ink)
    spaced(d, (cx + cw / 2, cy + 62), args.title.upper(), font("serif", 58), ink, 9)
    d.text((cx + cw / 2, cy + 125), args.subtitle, font=font("serif", 30, 1), fill=ink, anchor="mm")
    # compass rose
    rx, ry, r = W - pad - 150, pad + 160, 105
    for k in range(16):
        a = math.radians(k * 22.5 - 90)
        L = r if k % 4 == 0 else (r * 0.62 if k % 2 == 0 else r * 0.4)
        w = 16 if k % 4 == 0 else 9
        tip = (rx + L * math.cos(a), ry + L * math.sin(a))
        left = (rx + w * math.cos(a - math.pi / 2), ry + w * math.sin(a - math.pi / 2))
        right = (rx + w * math.cos(a + math.pi / 2), ry + w * math.sin(a + math.pi / 2))
        d.polygon([(rx, ry), left, tip], fill=paper, outline=ink)
        d.polygon([(rx, ry), right, tip], fill=ink, outline=ink)
    d.ellipse([rx - r * 0.75, ry - r * 0.75, rx + r * 0.75, ry + r * 0.75], outline=ink, width=2)
    d.ellipse([rx - 6, ry - 6, rx + 6, ry + 6], fill=paper, outline=ink, width=2)
    d.text((rx, ry - r - 26), "N", font=font("serif", 40), fill=ink, anchor="mm")
    # scale bar, alternating blocks
    mpp = metres_per_px(args.zoom, args.lat)
    L = nice_length(m.width * 0.25 * mpp)
    px = L / mpp
    sx, sy = W - pad - px - 40, H - pad - 70
    d.rectangle([sx - 20, sy - 50, sx + px + 20, sy + 40], fill=paper, outline=ink, width=2)
    for i in range(4):
        x0 = sx + i * px / 4
        d.rectangle([x0, sy, x0 + px / 4, sy + 12], fill=ink if i % 2 == 0 else paper, outline=ink, width=2)
    f = font("serif", 24, 1)
    for i, label in ((0, "0"), (2, str(L // 2)), (4, f"{L} Schritt" if args.paces else f"{L} m")):
        d.text((sx + i * px / 4, sy - 16), label, font=f, fill=ink, anchor="mm")
    return sheet


def la_sheet(m, args):
    grey, paper = (78, 77, 70), (247, 246, 242)
    pad = 70
    head = 150
    W, H = m.width + 2 * pad, m.height + 2 * pad + head
    sheet = Image.new("RGB", (W, H), paper)
    sheet.paste(m, (pad, pad))
    d = ImageDraw.Draw(sheet)
    d.rectangle([pad, pad, pad + m.width, pad + m.height], outline=grey, width=2)
    # title block below the plan
    ty = pad + m.height + 40
    d.line([pad, ty - 14, W - pad, ty - 14], fill=grey, width=1)
    spaced(d, (pad, ty + 22), args.title.upper(), font("sans", 44, 2), grey, 10, anchor="lm")
    d.text((pad, ty + 78), args.subtitle, font=font("sans", 24), fill=grey, anchor="lm")
    # north arrow (half-filled triangle) and scale bar on the right
    nx, ny = W - pad - 40, ty + 40
    d.polygon([(nx, ny - 46), (nx - 18, ny + 18), (nx, ny + 6)], fill=grey)
    d.polygon([(nx, ny - 46), (nx + 18, ny + 18), (nx, ny + 6)], outline=grey)
    d.text((nx, ny + 40), "N", font=font("sans", 22, 2), fill=grey, anchor="mm")
    mpp = metres_per_px(args.zoom, args.lat)
    L = nice_length(m.width * 0.2 * mpp)
    px = L / mpp
    sx, sy = nx - 90 - px, ty + 40
    for i in range(5):
        x0 = sx + i * px / 5
        d.rectangle([x0, sy, x0 + px / 5, sy + 8], fill=grey if i % 2 == 0 else paper, outline=grey, width=1)
    f = font("sans", 20)
    d.text((sx, sy - 16), "0", font=f, fill=grey, anchor="mm")
    d.text((sx + px, sy - 16), f"{L} m", font=f, fill=grey, anchor="mm")
    return sheet


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("style", choices=["ink", "la"])
    ap.add_argument("map")
    ap.add_argument("out")
    ap.add_argument("--zoom", type=int, default=17)
    ap.add_argument("--lat", type=float, default=52.477)
    ap.add_argument("--title", default="Schillerkiez")
    ap.add_argument("--subtitle", default="Neukölln · aus OpenStreetMap gezeichnet")
    ap.add_argument("--paces", action="store_true", help="label the ink scale bar in paces (fantasy touch)")
    ap.add_argument("--white", action="store_true", help="ink sheet on white paper (for SRK_INK_PAPER=white maps)")
    ap.add_argument("--legend", help="legend image from legend.py, placed in a band below the map")
    a = ap.parse_args()
    m = Image.open(a.map).convert("RGB")
    if a.legend:
        m = with_legend(m, Image.open(a.legend).convert("RGB"))
    out = (ink_sheet if a.style == "ink" else la_sheet)(m, a)
    out.save(a.out, quality=82)
    print(a.out, out.size)
