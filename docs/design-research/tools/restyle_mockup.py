#!/usr/bin/env python3
"""Turn a rendered Straßenraumkarte scene into a *target picture* for a style exploration.

This is a throw-away mockup tool, not the production path: it classifies the pixels of
an existing rendering by colour (see classify.py) and redraws the classes in a new style.
The real implementation must come from the data pipeline (SQL + QGIS), where buildings,
trees, playgrounds etc. are known from OSM tags instead of guessed from colours.

Usage:
  python restyle_mockup.py la  scene.png out.jpg [--landmark] [--seed 1]
  python restyle_mockup.py ink scene.png out.jpg [--landmark] [--seed 1]

Needs numpy, scipy, scikit-image, pillow, opencv-python-headless.
"""
import argparse
import math

import cv2
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi
from skimage.morphology import skeletonize

from classify import classify, clean

BG, BUILDING, ROAD, SIDEWALK, PATH, LAWN, TREE, WATER, OTHER = range(9)
SS = 2  # supersampling for vector-ish symbols


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.float32)


def fill_from_nearest(cls, holes):
    """Replace the class of `holes` pixels by the nearest non-hole class."""
    _, (iy, ix) = ndi.distance_transform_edt(holes, return_indices=True)
    out = cls.copy()
    out[holes] = cls[iy[holes], ix[holes]]
    return out


def boundary(mask, width=1):
    m = mask.astype(np.uint8)
    k = np.ones((2 * width + 1, 2 * width + 1), np.uint8)
    return (cv2.dilate(m, k) - cv2.erode(m, k)) > 0


def tree_points(tree_mask, rng, rmin=5, rmax=22):
    """Greedy disc packing inside the tree mask: single trees keep their own radius,
    woodland masses get many overlapping crowns."""
    dt = ndi.distance_transform_edt(tree_mask)
    ys, xs = np.nonzero(dt >= rmin)
    order = np.argsort(-dt[ys, xs] + rng.random(len(ys)) * 3)
    pts = []
    grid = {}
    cell = rmax
    for i in order:
        x, y = xs[i], ys[i]
        r = min(dt[y, x], rmax) * rng.uniform(0.9, 1.15)
        gx, gy = x // cell, y // cell
        ok = True
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for (px, py, pr) in grid.get((gx + dx, gy + dy), ()):
                    if (px - x) ** 2 + (py - y) ** 2 < (0.75 * max(pr, r)) ** 2:
                        ok = False
                        break
                if not ok:
                    break
            if not ok:
                break
        if ok:
            pts.append((x, y, r))
            grid.setdefault((gx, gy), []).append((x, y, r))
    return pts


def split_buildings(rgb, bmask):
    """Split building blocks into parts using the subtle shade differences of the source."""
    lum = cv2.GaussianBlur(rgb.mean(-1).astype(np.float32), (3, 3), 0)
    gx = cv2.Sobel(lum, cv2.CV_32F, 1, 0)
    gy = cv2.Sobel(lum, cv2.CV_32F, 0, 1)
    edges = (np.hypot(gx, gy) > 6) & cv2.erode(bmask.astype(np.uint8), np.ones((7, 7), np.uint8)).astype(bool)
    # keep only long, line-like edges (building part boundaries), drop texture speckle
    lab, n = ndi.label(edges, np.ones((3, 3)))
    sizes = ndi.sum(edges, lab, range(1, n + 1))
    edges = np.isin(lab, np.nonzero(sizes >= 40)[0] + 1)
    edges = skeletonize(edges)
    parts, n = ndi.label(bmask & ~cv2.dilate(edges.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool))
    # give edge pixels back to the nearest part
    _, (iy, ix) = ndi.distance_transform_edt(parts == 0, return_indices=True)
    parts = np.where(bmask, parts[iy, ix], 0)
    return parts, n, edges


def smooth_mask(mask, sigma=1.6):
    """Undo the stair-steps that the source's inner shadows leave on class edges."""
    m = ndi.binary_opening(mask, iterations=1)
    return cv2.GaussianBlur(m.astype(np.float32), (0, 0), sigma) > 0.5


def shift(mask, dx, dy):
    out = np.zeros_like(mask)
    h, w = mask.shape
    ys = slice(max(dy, 0), h + min(dy, 0))
    xs = slice(max(dx, 0), w + min(dx, 0))
    ys2 = slice(max(-dy, 0), h + min(-dy, 0))
    xs2 = slice(max(-dx, 0), w + min(-dx, 0))
    out[ys, xs] = mask[ys2, xs2]
    return out


def playground_mask(cls):
    """Mockup heuristic: compact, larger sand areas are playgrounds (+ the symbols on them)."""
    lab, n = ndi.label(cls == PATH)
    out = np.zeros(cls.shape, bool)
    for i, sl in enumerate(ndi.find_objects(lab), 1):
        comp = lab[sl] == i
        area = comp.sum()
        if area < 2500:
            continue
        hull = cv2.convexHull(np.argwhere(comp)[:, ::-1].astype(np.int32))
        if area / max(cv2.contourArea(hull), 1) > 0.55:
            out[sl] |= comp
    out = ndi.binary_closing(out, iterations=6)
    return ndi.binary_fill_holes(out)


def landmark_component(parts):
    """Mockup stand-in for building=church etc.: the building part nearest to the centre."""
    h, w = parts.shape
    best, bd = 0, 1e9
    for i, sl in enumerate(ndi.find_objects(parts), 1):
        if sl is None:
            continue
        cy, cx = ndi.center_of_mass(parts[sl] == i)
        d = math.hypot(sl[1].start + cx - w / 2, sl[0].start + cy - h / 2)
        if d < bd and (parts[sl] == i).sum() > 1500:
            best, bd = i, d
    return best


def scallop(cx, cy, r, rng, n=None, amp=0.07, steps=72):
    n = n or int(rng.integers(8, 14))
    ph = rng.uniform(0, 2 * math.pi)
    return [(cx + r * (1 + amp * math.sin(n * t + ph)) * math.cos(t),
             cy + r * (1 + amp * math.sin(n * t + ph)) * math.sin(t))
            for t in np.linspace(0, 2 * math.pi, steps, endpoint=False)]


def grain(shape, rng, strength=6.0, blur=1.2):
    g = rng.normal(0, 1, shape).astype(np.float32)
    g = cv2.GaussianBlur(g, (0, 0), blur)
    return g / (g.std() + 1e-6) * strength


def wobble(img, rng, amp=1.3, scale=40):
    h, w = img.shape[:2]
    def field():
        f = rng.normal(0, 1, (h // scale + 3, w // scale + 3)).astype(np.float32)
        return cv2.resize(f, (w, h), interpolation=cv2.INTER_CUBIC) * amp
    mx, my = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    return cv2.remap(img, mx + field(), my + field(), cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)


# --------------------------------------------------------------------------- landscape architecture
LA = {
    "paper": "#f2efe7", BG: "#ebe7dc", ROAD: "#bdb7ab", SIDEWALK: "#e2dbcd", PATH: "#e0cfa7",
    LAWN: "#cdd2ad", WATER: "#a7c2bf", "outline": "#2e2d2b",
    "roofs": [("#fbfaf6", 0.55), ("#e2dfd8", 0.2), ("#cfccc5", 0.12), ("#cf9377", 0.09), ("#bb7f66", 0.04)],
    "crowns": ["#9caa80", "#8d9e74", "#b1b58b", "#a8a479", "#7f9270", "#c3b386"],
}


def render_la(rgb, cls, rng, landmark=False):
    h, w = cls.shape
    base_cls = fill_from_nearest(cls, np.isin(cls, [TREE]))
    lum = rgb.mean(-1).astype(np.float32)
    out = np.zeros((h, w, 3), np.float32)
    for c in (BG, ROAD, SIDEWALK, PATH, LAWN, WATER):
        m = base_cls == c
        if not m.any():
            continue
        src = (cls == c) & m
        ref = lum[src].mean() if src.any() else lum[m].mean()
        # keep a little of the source texture (markings, cars, furniture) as luminance detail
        detail = np.where(cls == c, lum / ref, 1.0)[..., None]
        out[m] = (hexrgb(LA[c]) * np.clip(detail, 0.6, 1.15))[m]
    other = base_cls == OTHER
    out[other] = (np.array([0.95, 0.93, 0.9]) * lum[..., None])[other]  # cars & symbols: warm greyscale
    out[base_cls == BUILDING] = hexrgb(LA[BG])

    # lawn grain: pastel, slightly mottled like marker/pencil fill
    g = grain((h, w), rng, 5, 2.5)[..., None]
    out = np.where((base_cls == LAWN)[..., None], out + g, out)

    # building shadows (sun from NW, shadow to SE), multiplied onto the ground
    bmask = smooth_mask(cls == BUILDING)
    sh = np.zeros((h, w), np.float32)
    for k in range(1, 13):
        sh = np.maximum(sh, shift(bmask, k, k).astype(np.float32))
    sh = cv2.GaussianBlur(sh, (0, 0), 1.2) * (~bmask)
    out *= (1 - 0.2 * sh)[..., None]

    # tree layer, supersampled: shadow, crown, highlight, scalloped edge, branch strokes
    pts = tree_points(cls == TREE, rng)
    W, H = w * SS, h * SS
    shadow = Image.new("L", (W, H), 0)
    crowns = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ds = ImageDraw.Draw(shadow)
    for x, y, r in pts:
        o = 0.35 * r
        ds.ellipse([(x + o - r) * SS, (y + o - r) * SS, (x + o + r) * SS, (y + o + r) * SS], fill=110)
    for x, y, r in sorted(pts, key=lambda p: p[2]):
        col = hexrgb(LA["crowns"][int(rng.integers(len(LA["crowns"])))]) * rng.uniform(0.95, 1.05)
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        poly = [(px * SS, py * SS) for px, py in scallop(x, y, r, rng)]
        d.polygon(poly, fill=tuple(int(v) for v in col) + (215,))
        hi = 0.55 * r
        d.ellipse([(x - 0.25 * r - hi) * SS, (y - 0.25 * r - hi) * SS, (x - 0.25 * r + hi) * SS, (y - 0.25 * r + hi) * SS],
                  fill=tuple(int(min(255, v * 1.12)) for v in col) + (110,))
        dark = tuple(int(v * 0.62) for v in col)
        d.line(poly + [poly[0]], fill=dark + (230,), width=max(1, int(SS * 0.9)))
        if r > 7:
            for t in np.linspace(0, 2 * math.pi, int(rng.integers(5, 8)), endpoint=False) + rng.uniform(0, 1):
                d.line([((x + 0.12 * r * math.cos(t)) * SS, (y + 0.12 * r * math.sin(t)) * SS),
                        ((x + 0.62 * r * math.cos(t)) * SS, (y + 0.62 * r * math.sin(t)) * SS)], fill=dark + (120,), width=SS)
            d.ellipse([(x - 1.2) * SS, (y - 1.2) * SS, (x + 1.2) * SS, (y + 1.2) * SS], fill=dark + (200,))
        crowns.alpha_composite(layer)
    shadow = np.asarray(shadow.resize((w, h), Image.LANCZOS), np.float32) / 255
    shadow = cv2.GaussianBlur(shadow, (0, 0), 1.0) * (~bmask)
    out *= (1 - 0.35 * shadow)[..., None]

    # buildings: crisp outline, white/grey/terracotta roofs, thin part lines
    parts, n, edges = split_buildings(rgb, bmask)
    roof_cols, roof_p = zip(*LA["roofs"])
    choice = rng.choice(len(roof_cols), size=n + 1, p=np.array(roof_p) / sum(roof_p))
    # red roofs are an accent: only on smaller building parts, never on a whole block
    big = ndi.sum(np.ones_like(parts), parts, range(n + 1)) > 12000
    choice[big & (choice >= 3)] = rng.choice(3, size=int((big & (choice >= 3)).sum()))
    lut = np.array([hexrgb(roof_cols[c]) for c in choice])
    out[bmask] = lut[parts[bmask]]
    out[cv2.dilate(edges.astype(np.uint8), np.ones((2, 2), np.uint8)).astype(bool) & bmask] *= 0.8

    cr = np.asarray(crowns.resize((w, h), Image.LANCZOS), np.float32)
    a = cr[..., 3:] / 255
    out = out * (1 - a) + cr[..., :3] * a

    ol = boundary(bmask, 1) & cv2.dilate(bmask.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    out[ol] = out[ol] * 0.2 + hexrgb(LA["outline"]) * 0.8
    wb = boundary(cls == WATER, 1)
    out[wb] = out[wb] * 0.5 + hexrgb("#6f8f8c") * 0.5

    out += grain((h, w), rng, 2.5, 0.7)[..., None]  # paper grain
    return np.clip(out, 0, 255).astype(np.uint8)


# --------------------------------------------------------------------------- fantasy ink map
INK = "#2a241d"
ACCENT = "#c8452c"


def hatch(shape, spacing, angle, width=1, phase=0):
    h, w = shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    t = xx * math.cos(math.radians(angle)) + yy * math.sin(math.radians(angle)) + phase
    return (np.mod(t, spacing) < width)


def render_ink(rgb, cls, rng, landmark=False):
    h, w = cls.shape
    pg = playground_mask(cls)
    base_cls = fill_from_nearest(cls, np.isin(cls, [TREE, OTHER]))
    bmask = smooth_mask(base_cls == BUILDING)

    # parchment
    paper = hexrgb("#efe2c3")
    out = np.ones((h, w, 3), np.float32) * paper
    blot = cv2.GaussianBlur(rng.normal(0, 1, (h, w)).astype(np.float32), (0, 0), 60)
    blot = blot / (blot.std() + 1e-6)
    out *= (1 + 0.025 * blot)[..., None]
    yy, xx = np.mgrid[0:h, 0:w]
    vign = ((xx / w - 0.5) ** 2 + (yy / h - 0.5) ** 2)
    out *= (1 - 0.1 * vign)[..., None]
    out += grain((h, w), rng, 3, 0.8)[..., None]

    ink = np.zeros((h, w), np.float32)  # 0..1 ink coverage, drawn black/sepia at the end
    accent = np.zeros((h, w), np.float32)

    # plan-view ground: roads slightly darker with sparse stipple, curbs as lines
    road = base_cls == ROAD
    out[road] *= 0.94
    stip = rng.random((h, w))
    ink = np.maximum(ink, (road & (stip < 0.025)) * 0.55)
    path = (base_cls == PATH) & ~pg
    ink = np.maximum(ink, (path & (stip < 0.06)) * 0.7)
    ink = np.maximum(ink, boundary(road, 1) * 0.95)
    ink = np.maximum(ink, boundary(path, 0 + 1) * (hatch((h, w), 6, 0, 3) | hatch((h, w), 6, 90, 3)) * 0.6)
    side = base_cls == SIDEWALK
    ink = np.maximum(ink, boundary(side, 1) * 0.35)
    lawn = base_cls == LAWN
    # grass tufts
    tufts = Image.new("L", (w * SS, h * SS), 0)
    dt = ImageDraw.Draw(tufts)
    ys, xs = np.nonzero(lawn)
    for i in rng.choice(len(ys), size=min(len(ys), len(ys) // 900 + 1), replace=False):
        x, y = xs[i] * SS, ys[i] * SS
        for dx in (-3, 0, 3):
            dt.line([(x + dx * SS / 2, y), (x + dx * SS, y - 4 * SS)], fill=200, width=SS)
    ink = np.maximum(ink, np.asarray(tufts.resize((w, h), Image.LANCZOS), np.float32) / 255 * 0.8)
    ink = np.maximum(ink, boundary(lawn, 1) * 0.3)
    water = base_cls == WATER
    out[water] = out[water] * 0.9 + hexrgb("#c9d3c6") * 0.1
    waves = hatch((h, w), 7, 90, 1.2, phase=0) & water
    waves = wobble((waves * 255).astype(np.uint8), rng, 2.0, 12) > 100
    ink = np.maximum(ink, (waves & water) * 0.7)
    ink = np.maximum(ink, boundary(water, 1) * 1.0)

    # playground = the one category in colour
    accent = np.maximum(accent, boundary(pg, 1) * 1.0)
    accent = np.maximum(accent, (pg & hatch((h, w), 7, 45, 1.3)) * 0.55)
    symbols = pg & (cls == OTHER)
    accent = np.maximum(accent, cv2.dilate(symbols.astype(np.uint8), np.ones((2, 2), np.uint8)).astype(np.float32))

    # buildings in pseudo-3D (camera from the south): roofs shift north, south facades visible
    parts, n, edges = split_buildings(rgb, bmask)
    lm = landmark_component(parts) if landmark else -1
    blab, bn = ndi.label(bmask)
    objs = ndi.find_objects(blab)
    order = sorted(range(1, bn + 1), key=lambda i: objs[i - 1][0].stop)
    for i in order:
        m = blab == i
        if m.sum() < 30:
            continue
        hh = int(rng.integers(13, 19)) if m.sum() > 400 else 8
        if lm > 0 and (parts[m] == lm).any():
            hh = 30
        vol = m.copy()
        for k in range(1, hh + 1):
            vol |= shift(m, 0, -k)
        roof = shift(m, 0, -hh)
        wall = vol & ~roof
        # occlude whatever is behind (north of) this building
        out[vol] = paper * 0.99
        ink[vol] = 0
        accent[vol] = 0
        # facade: light vertical strokes + window ticks
        win = hatch((h, w), 9, 0, 1.6) & (np.mod(yy - 2, 8) < 3)
        ink[wall] = np.maximum(ink[wall], (win[wall]) * 0.6)
        out[wall] *= 0.93
        # roof: diagonal hatching, roof-part lines
        rh = hatch((h, w), 5, 45, 1.1)
        ink[roof] = np.maximum(ink[roof], rh[roof] * 0.4)
        e = shift(edges & m, 0, -hh)
        ink = np.maximum(ink, e * 0.9)
        ink = np.maximum(ink, boundary(vol, 1) * 1.0)
        ink = np.maximum(ink, boundary(roof, 1) * (roof | wall) * 0.95)
    if lm > 0:
        cy, cx = ndi.center_of_mass(parts == lm)
        tower = Image.new("L", (w, h), 0)
        td = ImageDraw.Draw(tower)
        x0 = int(cx) - 9
        y0 = int(cy) - 30
        td.rectangle([x0, y0 - 46, x0 + 18, y0], fill=1)
        td.polygon([(x0 - 2, y0 - 46), (x0 + 9, y0 - 92), (x0 + 20, y0 - 46)], fill=2)
        t = np.asarray(tower)
        out[t > 0] = paper
        ink[t > 0] = 0
        ink = np.maximum(ink, boundary(t > 0, 1) * 1.0)
        ink = np.maximum(ink, ((t == 2) & hatch((h, w), 3, 60, 1)) * 0.8)
        ink = np.maximum(ink, ((t == 1) & hatch((h, w), 6, 0, 1.4) & (np.mod(yy, 9) < 4)) * 0.8)
        cross = Image.new("L", (w, h), 0)
        cd = ImageDraw.Draw(cross)
        cd.line([(x0 + 9, y0 - 92), (x0 + 9, y0 - 104)], fill=255, width=2)
        cd.line([(x0 + 4, y0 - 99), (x0 + 14, y0 - 99)], fill=255, width=2)
        ink = np.maximum(ink, np.asarray(cross, np.float32) / 255)

    # trees as side-view crowns, painter's order south-most last
    pts = tree_points(cls == TREE, rng, rmin=4, rmax=17)
    W, H = w * SS, h * SS
    tl = Image.new("L", (W, H), 0)     # ink
    tf = Image.new("L", (W, H), 0)     # occluding fill
    for x, y, r in sorted(pts, key=lambda p: p[1]):
        cx, cy = x, y - 0.75 * r
        fill_layer = ImageDraw.Draw(tf)
        line_layer = ImageDraw.Draw(tl)
        crown = [(px * SS, py * SS) for px, py in scallop(cx, cy, r, rng, amp=0.09)]
        # erase ink below the crown (occlusion), then draw
        line_layer.polygon(crown, fill=0)
        fill_layer.polygon(crown, fill=255)
        line_layer.line([(x * SS, y * SS), (x * SS, (cy + 0.4 * r) * SS)], fill=255, width=int(1.4 * SS))
        line_layer.line(crown + [crown[0]], fill=255, width=int(1.2 * SS))
        # shading: short strokes in the lower right part of the crown
        for _ in range(int(r * 0.9)):
            a = rng.uniform(-0.3, 1.9)
            rr = rng.uniform(0.35, 0.85) * r
            px, py = cx + rr * math.cos(a), cy + rr * math.sin(a)
            line_layer.line([(px * SS, py * SS), ((px - 0.18 * r) * SS, (py + 0.18 * r) * SS)], fill=200, width=SS)
        # ground shadow tick
        line_layer.line([((x - 0.5 * r) * SS, (y + 1) * SS), ((x + 0.7 * r) * SS, (y + 1) * SS)], fill=160, width=SS)
    tf = np.asarray(tf.resize((w, h), Image.LANCZOS), np.float32) / 255
    tl = np.asarray(tl.resize((w, h), Image.LANCZOS), np.float32) / 255
    out = out * (1 - tf[..., None]) + paper * 1.0 * tf[..., None]
    ink = ink * (1 - tf) + tl
    accent *= (1 - tf)

    ink = wobble(np.clip(ink, 0, 1), rng, 0.9, 30)
    accent = wobble(np.clip(accent, 0, 1), rng, 0.9, 30)
    acc_wash = cv2.GaussianBlur(pg.astype(np.float32), (0, 0), 1.5) * (1 - tf) * 0.18
    out = out * (1 - acc_wash[..., None]) + hexrgb(ACCENT) * acc_wash[..., None]
    out = out * (1 - ink[..., None] * 0.92) + hexrgb(INK) * (ink[..., None] * 0.92)
    out = out * (1 - accent[..., None]) + hexrgb(ACCENT) * accent[..., None]
    return np.clip(out, 0, 255).astype(np.uint8)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("style", choices=["la", "ink"])
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--landmark", action="store_true", help="draw the central building as landmark (ink only)")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    rgb = np.asarray(Image.open(a.src).convert("RGB"))
    cls = clean(classify(rgb))
    img = (render_la if a.style == "la" else render_ink)(rgb, cls, rng, a.landmark)
    Image.fromarray(img).save(a.out, quality=88)
    print(a.out)
