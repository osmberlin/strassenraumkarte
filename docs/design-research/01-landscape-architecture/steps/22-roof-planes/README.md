# LA 22 — roof planes

Roof data from `roof_shape.sql` (see [ROOF-SHAPES.md](../../../ROOF-SHAPES.md)) on the white buildings:

- every roof **facet** gets a very light tone, darker on planes facing away from the NW light (the same light as the SE shadow) — buildings read as volumes without losing the white;
- **ridges** as hairlines; hips and parapets are not drawn (a site plan shows planes, not construction lines);
- from z17, `SRK_ROOFS=off` switches back, automatic fallback without roof tables.

**Look at:** `before-after.jpg`, scene B (perimeter blocks).
