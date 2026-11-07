import numpy as np
from PIL import Image
from scipy import ndimage as ndi

CLASSES = ['bg','building','road','sidewalk','path','lawn','tree','water','other']

def classify(rgb):
    a = rgb.astype(np.float32)
    r, g, b = a[...,0], a[...,1], a[...,2]
    mx = a.max(-1); mn = a.min(-1); L = a.mean(-1)
    d = g - r; yb = (r + g) / 2 - b
    cls = np.full(r.shape, 8, np.uint8)
    neutral = (mx - mn) < 10
    cls[neutral & (L > 185)] = 0
    cls[neutral & (L <= 185) & (L > 110)] = 2
    cls[(r - g > 4) & (r - b > 3) & (L > 185) & (b > 170) & (yb < 26)] = 1
    cls[(d <= 8) & (d >= -4) & (yb > 8) & (yb <= 24) & (L > 200)] = 3
    cls[(d <= 8) & (yb > 24) & (L > 175)] = 4
    cls[(d > 8) & (L >= 196)] = 5
    cls[(d > 8) & (L < 196)] = 6
    cls[(b - r > 25) & (b > 150)] = 7
    return cls

def clean(cls, k=2):
    # majority filter to remove anti-aliasing speckle
    out = cls.copy()
    best = np.zeros(cls.shape, np.float32)
    for c in range(len(CLASSES)):
        m = ndi.uniform_filter((cls == c).astype(np.float32), 2 * k + 1)
        upd = m > best
        out[upd] = c; best[upd] = m[upd]
    return out

PREVIEW = np.array([[236,236,236],[220,80,80],[90,90,90],[240,220,180],[230,190,40],[150,220,120],[20,120,40],[60,90,230],[255,0,255]],np.uint8)

if __name__ == '__main__':
    import sys
    rgb = np.asarray(Image.open(sys.argv[1]).convert('RGB'))
    c = clean(classify(rgb))
    Image.fromarray(PREVIEW[c]).save(sys.argv[2])
    print({CLASSES[i]: int((c==i).sum()) for i in range(9)})
