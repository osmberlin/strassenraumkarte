# 08 — Sub-pixel lines: as much ink as QGIS

Columns: QGIS · vector after step 07 · vector now. Renderer patch
([maplibre-patches.md](../../maplibre-patches.md)) plus two style fixes.

The problem: thin dark lines along building parts, roof edges and footlines looked crisp and
pixelated, where QGIS shows a soft grey hint.

Cause 1 — MapLibre's line shader. A line narrower than one pixel is drawn as a ramp about one
pixel wide peaking at 50 % alpha or more, however thin the line is: `(w/2 + 0.5)²` px of ink,
never less than 0.25 px. A 0.05 px part outline at z17 comes out several times too strong.

The patch rescales the alpha of lines below one device pixel so the ink is `w·(2 − w)`. That
curve was fitted to QGIS, not derived: `vector/scripts/line-ink.ts` projects the
`building_lines` geometry into the screenshots and integrates the darkening across each line.

| Zoom (line width) | QGIS | unpatched | ink = w (first attempt) | ink = w·(2 − w) |
|---|---|---|---|---|
| z17 (0.06–0.14 px) | 0.18–0.19 | 0.44–0.49 | 0.10–0.19 | 0.17–0.32 |
| z18 (≈ 0.27 px) | 0.67 | 0.55 | 0.33 | 0.55 |
| z19 (≈ 0.55 px) | 0.83 | 0.71 | 0.61 | 0.86 |

(median ink in pixels of full line colour.) The first attempt used plain coverage, `ink = w`;
that was clearly too faint — lines almost vanished. QGIS puts down roughly twice the geometric
coverage for these widths.

Cause 2 — the port. It drew a pale pink outline around every building part (the whitish line);
QGIS draws parts without outline. And `footline_covered` was one dashed grey line instead of
QGIS's solid light grey line with a thinner dashed grey one on top.

What to look at: building-part edges in [dense-housing.jpg](./dense-housing.jpg) and
[intersection.jpg](./intersection.jpg).

Honest limits:

- QGIS lines are also *softer* — about three pixels wide with a low peak, from tile resampling
  and JPEG compression. Ours carry the same ink in one crisp pixel. The pixelmatch score
  therefore does not improve with this step (dense housing 5.2 % → 5.1 %), although the lines
  look much closer.
- The curve is fitted on three zoom levels of one line colour. It is global: every sub-pixel
  line in the style changes.

![Dense housing](./dense-housing.jpg)
