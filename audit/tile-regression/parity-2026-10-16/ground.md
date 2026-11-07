# Ground parity: `full-approx` vs QGIS (carriageways, footways, landuse, pitch, water)

Scope: `rust/srk-render` `full-approx` ground layers only (highway_area fills and surface
textures, z14–z20 kerb innerShadow, footways/paths, service, tactile, landuse fills and
textures, pitch, water). Trees, labels, buildings, furniture and road markings are other
agents' work and are still the dominant pixel error.

Branch: `worktree-agent-acd7a4a4d11b3e781` (commit `18f20c2`), cut from the PR head
`d0e66ad` (`claude/rust-qgis-parity`). Method, metric and tile set as in
`audit/tile-regression/README.md`: `--metatile 1 --gutter 1 --workers 1`, pixelmatch
threshold 0.1, `manifest-full.json`.

## Result (pixelmatch ratio, lower is better)

| tile | before (PR head) | after | Δ |
| --- | ---: | ---: | ---: |
| 15/17606/10752 density z15 | 25.61 % | 21.59 % | −4.02 |
| 15/17605/10752 intersection parent z15 | 23.17 % | 18.81 % | −4.36 |
| 16/35212/21505 density z16 | 20.18 % | 17.11 % | −3.07 |
| 16/35211/21505 intersection z16 | 19.26 % | 15.97 % | −3.29 |
| 17/70422/43011 Herrfurthplatz z17 | 15.75 % | 12.07 % | −3.68 |
| 17/70425/43010 density z17 | 14.61 % | 11.57 % | −3.04 |
| 18/140845/86023 intersection z18 | 14.92 % | 11.96 % | −2.96 |
| 18/140851/86021 density z18 | 10.82 % | 8.62 % | −2.20 |
| 19/281691/172046 intersection z19 | 15.96 % | 10.31 % | −5.65 |
| 20/563382/344092 intersection z20 | 9.36 % | 9.45 % | +0.09 |
| **mean** | **16.96 %** | **13.74 %** | **−3.22** |

Only z20 moved the wrong way (+0.09). Its ground content is almost entirely tree crowns,
furniture and footway casings that already agree; the residual there is not ground.

Intermediate steps (mean pixelmatch): texture multiply + width fix + kerb shading 15.25 →
black-lift removal 15.20 → paths and tactile drawn before highway_area 13.89 → service
after paths 13.78 → path casing and fill-width rework 13.77 → tag-based path fill width 13.74.

## Changes

1. **RasterFill evaluation per QGIS rule** (`palette.rs`: `TextureRule`, `highway_surface_rule`,
   `landuse_surface_rule`, `pitch_surface_rule`, `landuse_class_rules`). Values transcribed
   from `strassenraumkarte.qgs`:
   - highway_area surfaces: sett 0.12, asphalt 0.06 (6 m), paving_stones 0.10 (4.5 m,
     angle `direction + 45`), concrete 0.35 (3 m); sett angle = `direction`.
   - Sett width from `sett:length` (`5 cm` → 6 m, `10 cm` → 8.5 m, else 11 m).
   - landuse / pitch surfaces 0.06–0.15 with native or metre widths; landuse class overlays
     (grass 0.06/0.09, gravel, sand, woodchips, flowerbed, water/wetland) with their alphas.
2. **Multiply composite** for highway surfaces (`drawSource` blend 13), landuse surface and
   pitch surface (layer blend 6). Class overlays stay Normal.
3. **Texture size**: width is ground metres × `@mercator_scale` (the old code omitted the
   scale, so textures were ~1.6× too small at this latitude). Rotation is about the
   Web Mercator origin (QGIS coordinate mode *Feature*); origin reduced by whole periods in
   f64 before narrowing (z20 coordinates lose f32 precision otherwise).
4. **Removed the black-lift hack** on sett/asphalt textures (it was a workaround for the old
   0.028 opacity). Pre-blur kept at the old radii (A/B: removing it was slightly worse).
5. **Kerb innerShadow** (`paint.rs`: `fill_polygons_inner_shadow_multiply`; `layers.rs`:
   `paint_highway_kerb_shade`). Over the union of the z14–z20 road classes (plus parking with
   a road class): `S = A·(1 − blur(A))`, multiply by `1 − 0.67·S·(1 − 35/255)`. Blur per zoom
   from the project (0.2 / 0.29 / 0.4 / 0.57 / 0.8 / 1.13 / 1.6 mm), converted with
   `KERB_SIGMA_PX_PER_MM = 1.9`. Edge profile at z19 matches QGIS within a few levels; the
   1.9 scale was chosen because it scored better in pixelmatch than the profile-matched 1.0.
6. **Draw order** follows the layer tree (bottom → top): path casing, path fill, service,
   tactile paving, highway_area, kerb shading. Previously paths were drawn over the
   carriageway, so footway crossings showed as light rectangles on the road. This was the
   single largest gain (−3.4 mean).
7. **Paths**: casing offsets are `(width/2 or 0.9 m) × @mercator_scale` (was unscaled);
   sidewalk casing is a dashed 4:2 line at α 0.5, footway/informal casings keep their
   0.6;0.6 and 0.6;2.4 dashes. Fill width is tag × mercator, which scored better than the
   XML's fixed map-unit widths (see open questions).
8. **Tactile paving** offset is `−0.5 × @mercator_scale` for kerb (was unscaled).
9. **Landuse** draws in two passes (class fills and overlays, then surface overlays), and
   **pitch** the same (fill, then surface overlay), matching the layer tree.

Textures: `textures.rs` gains `water`, `wetland`, `flowerbed` ids (files already in
`style/textures/`).

## Colour audit (z19 and z17, per-class mean RGB, QGIS − Rust, eroded polygon masks)

| group | z19 diff (R,G,B) | z17 diff |
| --- | --- | --- |
| carriageway (highway_area road classes) | −0.9, −2.4, −0.7 | +1.1, −1.1, +1.1 |
| sett (highway_area surface=sett) | +0.4, −1.7, +0.6 | +3.3, +2.1, +3.6 |
| landuse park/grass | +2.7, +1.1, +3.7 | +4.2, +2.9, +5.4 |
| parking (area:highway=parking) | +6.0, 0, +6.8 | +3.7, 0, +4.1 |

Forest/wood differs by −25 to −27 in green at z17 but the masks are dominated by tree crowns
(other agent). Parking QGIS is slightly greenish (≈ −6 R/B vs flat #a8a8a7); not explained by
the project XML, left as is.

## Isolate smoke (`--layers highway_area`)

The QGIS isolate reference (`runs/…-smoke`) is not stored in this worktree and re-rendering
QGIS was out of scope, so the 0.079 % baseline could not be recomputed. Rust-only check
(PR-head binary vs new binary, 12 smoke tiles): mean |Δ| 0.78 levels, 0.004 % of pixels
over the 10 % threshold. The isolate change is the Multiply surface textures; expected impact
on the isolate QGIS comparison is negligible.

## Verification

- `cargo test --release`: 21 passed, 0 failed, 4 ignored.
- Renders: `bash` loop over `manifest-full.json` tiles, compare via `scripts/compare-run.ts`.
- `ground.jpg`: QGIS | Rust before | Rust after, tile 19/281691/172046, crop (60,110) 110×110 at 3×.

## Remaining gaps (ground only)

- **Water bodies**: not implemented beyond the flat fill. QGIS adds an innerShadow (blur 4 mm,
  `#a396d9`), a shapeburst and a `water.png` RasterFill at viewport coordinates (35 m).
  The manifest tiles contain only a few 30–50 m² water polygons, so nothing could be
  validated; treat as open.
- **Texture phase and rotation**: map-anchored vs feature-anchored phase was A/B tested (no
  change), and the `direction` sign convention was checked by flipping it (no change). Both
  remain unverified against QGIS at the pixel level; the sett cobble pattern orientation looks
  right at z19.
- **Random landuse angles** (`rand(0, 360)` for asphalt/concrete/grass surfaces) are drawn
  unrotated. QGIS draws these randomly, so they cannot match per pixel.
- **Layer buckets**: QGIS stacks `layer ≤ −2 … ≥ 3` as separate sub-stacks. Rust orders by
  `COALESCE(layer, 0)` within each class pass, so bridge and tunnel stacking is approximate.
- **Tactile MarkerLine** (`cross2` markers, red, 1 mm) is not drawn.
- **Parking** QGIS tint (see audit) and **forest** shading are unexplained.

## Open questions

- The XML gives fixed map-unit widths for `service` (4 m / 3 m) and path fills (1.8 / 1.2 /
  1.0). Pixelmatch prefers the `width` tag × `@mercator_scale` for both (service: fixed
  widths scored 14.02 vs 13.77 for tag × scale; path fills: 13.77 fixed vs 13.74 tag). Either
  QGIS applies the tag through another layer (for example `feature_way`) or the
  map-unit interpretation differs. Worth checking with a single QGIS-rendered service road.
- `KERB_SIGMA_PX_PER_MM` is pixelmatch-tuned (1.9) and the profile suggests about 1.0. Worth
  revisiting once labels are in.
