# LA 20 — tree legend, water names, oak symbol

- **Tree legend** (`legend.jpg`, sage and vivid): drawn by the renderer's own `draw_crown` via the ignored test `la_tree_legend` in `style_la_extra.rs`; `docs/design-research/tools/la_tree_legend.sh out.png` builds the labelled sheet. Symbols at their genus default crown size (1 m = 6 px).
- **Oak** fixed: the sub-crowns were one even-odd path, so the overlaps cancelled into a "flower". Now each sub-crown is filled into an opaque layer and composited translucent, with a slightly smaller outer scallop. Birch stipple lighter and sparser.
- **Water names** (`water_body.name`, z17+): italic Avenir Next in the dark bank colour with a pale water halo, centred on the water, skipped when the name does not fit. Cartographic rule: water italic, land upright.

**Look at:** `legend.jpg`, `water.jpg` (Rixdorfer Teich in the Hasenheide at z18, Weltenmeer at z19).
