# Ink 22 — roof shapes from processing

Roofs now come from `data/processing/sql/roof_shape.sql` (branch `design-roof-shapes`, see [ROOF-SHAPES.md](../../../ROOF-SHAPES.md)): touching buildings of the same roof kind are merged into one **roof mass**, hipped masses get their planes from the straight skeleton, gabled ones from a centreline split.

- Plan-view buildings that belong to a sloped mass lose their per-building slope hatch and ridge. Instead every **facet** is hatched along its ridge (perpendicular to the downslope bearing), facets facing away from the NW light get a second hatch (cross-hatch), and **ridges** (heavy) and **hips** (lighter) are drawn on top.
- The hatch is clipped to each facet analytically (`hatch_in_polygon` in `style_kit.rs`) — no mask per facet, world-anchored like all other hatches.
- Two passes: plan-view buildings, then the facets, then lifted (oblique variant) buildings on top. Flat roofs keep the old single hatch.
- From z17; `SRK_ROOFS=off` switches back. Without the roof tables (e.g. a DB imported before this step) the old drawing is used automatically.

**Look at:** `before-after.jpg` — perimeter blocks now read as one continuous hipped roof with hips at the corners instead of strips per house. Known issue: small bowtie facets where narrow courtyard wings meet (see ROOF-SHAPES.md, next steps).
