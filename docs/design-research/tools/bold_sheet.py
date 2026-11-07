#!/usr/bin/env python3
"""Stitch z19 tiles of the `bold` preset into one A0 print sheet (double frame, caption plate, scale bar, north mark).

    python3 bold_sheet.py <tiles-dir> <out.png> --title NEUKÖLLN [--crop lon,lat,name ...] [--crop-dir DIR]
    python3 bold_sheet.py <tiles-dir> <out.png> --jpg sheet.jpg --jpg-width 4000

Layout only; tiles come from `srk-render --layers bold --format png --zmin 19 --zmax 19`.
Sizes (frame, text) are in full-resolution pixels; the map is ~0.18 m/px (A0 landscape at ~300 dpi).
"""
import argparse, glob, math, os
from PIL import Image, ImageDraw, ImageFont

Image.MAX_IMAGE_PIXELS = None
PAPER, INK = (243, 240, 232), (20, 20, 20)
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"  # index 4 = Condensed? we probe for the bold face below


def bold_font(size):
    for idx in range(0, 8):
        try:
            f = ImageFont.truetype(FUTURA, size, index=idx)
            if "Bold" in " ".join(f.getname()) and "Condensed" not in " ".join(f.getname()):
                return f
        except OSError:
            break
    return ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", size, index=8)


def spaced(d, cx, cy, text, fnt, spacing, fill=INK):
    ws = [d.textlength(c, font=fnt) for c in text]
    x = cx - (sum(ws) + spacing * (len(text) - 1)) / 2
    for c, w in zip(text, ws):
        d.text((x, cy), c, font=fnt, fill=fill, anchor="lm")
        x += w + spacing


def stitch(tiles_dir, z=19):
    xs = sorted(int(os.path.basename(p)) for p in glob.glob(f"{tiles_dir}/{z}/*"))
    x0, x1 = xs[0], xs[-1]
    ys = [int(os.path.basename(p)[:-4]) for p in glob.glob(f"{tiles_dir}/{z}/*/*.png")]
    y0, y1 = min(ys), max(ys)
    m = Image.new("RGB", ((x1 - x0 + 1) * 256, (y1 - y0 + 1) * 256), PAPER)
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            p = f"{tiles_dir}/{z}/{x}/{y}.png"
            if os.path.exists(p):
                m.paste(Image.open(p).convert("RGB"), ((x - x0) * 256, (y - y0) * 256))
    return m, x0, y0


def lonlat_px(lon, lat, x0, y0, z=19):
    n = 2 ** z
    xf = (lon + 180) / 360 * n
    yf = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return (xf - x0) * 256, (yf - y0) * 256


def sheet(m, title, lat):
    M, OUT_INSET, OUT_W, IN_W = 400, 110, 30, 15
    W, H = m.width + 2 * M, m.height + 2 * M
    s = Image.new("RGB", (W, H), PAPER)
    s.paste(m, (M, M))
    d = ImageDraw.Draw(s)
    d.rectangle([M - IN_W, M - IN_W, W - M + IN_W - 1, H - M + IN_W - 1], outline=INK, width=IN_W)   # inner, thin
    d.rectangle([OUT_INSET, OUT_INSET, W - OUT_INSET - 1, H - OUT_INSET - 1], outline=INK, width=OUT_W)  # outer, heavy
    # caption plate straddling the bottom frame
    cx, cy = W / 2, H - OUT_INSET - OUT_W / 2
    f = bold_font(190)
    text = "•  " + "  ".join(title) + "  •" if False else title
    label = "•"
    sp = 70
    tw = sum(d.textlength(c, font=f) for c in title) + sp * (len(title) - 1)
    dot_r, gap = 26, 130
    pw, ph = tw + 2 * (gap + 2 * dot_r + 90), 330
    box = [cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2]
    d.rectangle(box, fill=PAPER, outline=INK, width=OUT_W)
    d.rectangle([b + (22 if i < 2 else -22) for i, b in enumerate(box)], outline=INK, width=IN_W)
    spaced(d, cx, cy - 8, title, f, sp)
    for sgn in (-1, 1):
        x = cx + sgn * (tw / 2 + gap)
        d.ellipse([x - dot_r, cy - dot_r, x + dot_r, cy + dot_r], fill=INK)
    # scale bar, bottom-left, in the band between inner and outer frame
    mpp = 156543.03392 * math.cos(math.radians(lat)) / 2 ** 19
    L = 500
    px = L / mpp
    sx = M + 120
    sy = H - M + (M - OUT_INSET - OUT_W - IN_W) / 2 + 40
    bh = 34
    for i in range(2):
        d.rectangle([sx + i * px / 2, sy, sx + (i + 1) * px / 2, sy + bh], fill=INK if i % 2 == 0 else PAPER, outline=INK, width=8)
    fs = bold_font(64)
    for i, lab in enumerate(("0", "250", "500 m")):
        d.text((sx + i * px / 2, sy - 22), lab, font=fs, fill=INK, anchor="ms" if i < 2 else "ls")
    # north mark, bottom-right: thick-line arrow
    nx, ny = W - M - 260, H - M + (M - OUT_INSET - OUT_W - IN_W) / 2
    d.polygon([(nx, ny - 95), (nx + 52, ny + 70), (nx, ny + 28), (nx - 52, ny + 70)], fill=INK)
    d.text((nx, ny - 120), "N", font=bold_font(110), fill=INK, anchor="ms")
    # credit
    d.text((W - OUT_INSET - OUT_W, H - OUT_INSET / 2 + 12), "© OpenStreetMap contributors", font=bold_font(46), fill=INK, anchor="rm")
    return s


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("tiles"); ap.add_argument("out")
    ap.add_argument("--title", default="NEUKÖLLN")
    ap.add_argument("--lat", type=float, default=52.4755)
    ap.add_argument("--jpg"); ap.add_argument("--jpg-width", type=int, default=4000)
    ap.add_argument("--crop", action="append", default=[], help="lon,lat,name")
    ap.add_argument("--crop-dir", default=".")
    ap.add_argument("--crop-size", default="1600x1100")
    a = ap.parse_args()
    m, x0, y0 = stitch(a.tiles)
    print("map", m.size)
    s = sheet(m, a.title, a.lat)
    s.save(a.out, optimize=False, compress_level=3)
    print("sheet", s.size, a.out)
    if a.jpg:
        h = round(s.height * a.jpg_width / s.width)
        s.resize((a.jpg_width, h), Image.LANCZOS).save(a.jpg, quality=85, optimize=True)
    cw, ch = map(int, a.crop_size.split("x"))
    for c in a.crop:
        lon, lat, name = c.split(",")
        px, py = lonlat_px(float(lon), float(lat), x0, y0)
        l, t = int(px - cw / 2), int(py - ch / 2)
        l = max(0, min(m.width - cw, l)); t = max(0, min(m.height - ch, t))
        m.crop((l, t, l + cw, t + ch)).save(f"{a.crop_dir}/detail-{name}.jpg", quality=88)
        print("crop", name, l, t)
