# Ink 26 — trees like the first mockup

Solitary trees and woodland go back to the symbol of the first procedural mockup ([`mockups/overview.jpg`](../../mockups/overview.jpg), right column; `docs/design-research/tools/restyle_mockup.py`, `render_ink`). Step 14 had merged the woodland into one cloud silhouette with light arcs inside, and the street trees were small upright scalloped crowns. Both looked like a different drawing from the mockups.

## What changed

- **One crown symbol for everything** (`draw_crown` in `style_ink.rs`, replacing `draw_tree`): a bubbly outline of 7–10 rounded lobes (12 % of the radius), a light world-anchored wobble, paper fill, a trunk stub and a ground tick, as in the mockup.
- **Shading on the side away from the light:** short diagonal strokes across the lower-right half (about 1.2 strokes per pixel of radius), plus a darker accent arc just inside the lower-right edge. Light stays north-west.
- **Woodland is individual crowns:** the cloud silhouette and its inner arc pattern are gone. Every crown of a wood (scatter from the 5 m cell, scaled by √2 per zoom level below z19, and mapped trees inside `landuse=forest|wood`) is drawn with the same symbol, sorted north → south, each with its own paper fill, so the crowns in front overlap the ones behind. Crown radii vary by ±20 % per crown so the wood is not a regular grid.
- **Unchanged:** conifers (stacked triangles), crown sizes from `diameter_crown`, the accent (`SRK_ACCENT=tree` recolours the crown outline and shading), the seam-safe world-anchored randomness.

## Checks

- `seam_check.sh ink`: mean 0.002 %, worst 0.01 % (limit 0.1 %).
- `cargo test --release`: 21 passed.
- Speed: scenes c and f at z19, same machine, same run: 74 ms/tile before, 72 ms/tile after.
- Legend "Wald" and the tree samples are rendered by `srk-render`, so they change with the style (`legend.py ink` regenerated).
- Compared side by side with the mockup for scenes a and c, and checked at z17 (c and f): the crowns stay readable there.
