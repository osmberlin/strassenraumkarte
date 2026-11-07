# LA 06 — soft shadows and watercolour rims

- New layer tools in `style_kit.rs`: `new_layer`, `blur_layer` (3× box blur ≈ gaussian), `draw_layer` (opacity + blend mode).
- Building shadow: one SE sweep, blurred ~0.35 m, multiplied at 34 %. Tree shadows blurred ~0.6 m, 26 %.
- Lawns get a darker rim along their edges (stroke inside the lawn mask, blurred, multiplied) — the bled edge of a watercolour wash.

**Look at:** `detail.jpg` — lawn edges around the paths of Herrfurthplatz.
