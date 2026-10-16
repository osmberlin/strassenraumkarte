# Ink 24 — one light, from the north-west

Until now the ink style had two lights. Roofs from the facets (step 22) and the landscape-architecture style used light from the **north-west** (azimuth 315°). The older ink shading still assumed **south-west**: the cross-hatched half of per-building roofs was the NE half, and the shadows of lifted buildings fell east-north-east. Both now follow the same light as the facets.

## What changed

- **Per-building roofs** (flat or unroofed buildings, and every lifted building): the cross-hatched shaded half is the side facing the shadow direction, south-east. It was north-east. The facets already hatched the SE/E/S-facing planes, so both kinds of roof now shade alike.
- **Lifted buildings** (`SRK_INK_OBLIQUE=freestanding`): the hatched ground shadow falls south-east, the direction of the light's shadow, instead of east-north-east.
- **Bridge parapets** (`style_ink_extra.rs`): the hatched shadow strokes under a south parapet lean south-east.
- **One source for the light:** `roof_shapes::LIGHT_AZIMUTH_DEG = 315°`, with `lit_factor` (facets) and `shadow_dir_px` (pixel direction of cast shadows, south-east). Every ink shading direction is derived from these. A unit test checks that a facet is in shade exactly when it faces the shadow direction, and that this agrees with `lit_factor`.

## Checked and already consistent (unchanged)

- Tree crowns: shading strokes on the lower right (SE side).
- Woodland crowns: the arc and shading strokes on the lower side of each crown.
- Spire, clock tower and bell turret: their shading (ticks, right-hand half) is on the east face, which faces away from the NW light.
- Roof facets (`draw_roof_facets`): already NW.
- Facade bands (plan south bands and the south walls of lifted buildings): a uniform paper tint with window ticks. They carry no direction, so they are unchanged.

## Look at

- `before-after.jpg`: the step before (22) against this step. Most of the map is identical. The difference is confined to the shaded side of per-building roofs and to the shadows of lifted buildings.
- `sheet-obl.jpg`: scenes A–D with `SRK_INK_OBLIQUE=freestanding`. The lifted groups now cast their shadow south-east, below and to the right of the building.

## Checks

- `cargo test --release`: green (21 tests + the new `shade_follows_the_shadow_direction`).
- `seam_check.sh ink`: 0.002 % mean, worst tile 0.01 %. With `SRK_INK_OBLIQUE=freestanding`: 0.002 % mean, worst 0.02 %.
- Clippy: no new warnings in the touched files; the existing ones remain.
