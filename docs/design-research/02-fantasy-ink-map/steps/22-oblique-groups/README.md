# Ink 22 — oblique view for small connected groups

- With `SRK_INK_OBLIQUE=freestanding`, connected clusters of up to 6 buildings and 1800 m² (kind `group`) are lifted together with one shared lift (the tallest height in the cluster), so semi-detached houses, rows of huts and L-shaped houses get one roof line, and each building keeps its own roof outline.
- No wall is drawn between two members of the same lifted group.
- Clusters are computed in SQL (DBSCAN, 0.8 m) over a window 300 m wider than the tile, so the cluster stats do not depend on the tile drawn. Seam check: default 0.087 %, oblique 0.105 %, unchanged.
- Larger clusters (blocks, city courtyards) and rows stay in plan view; the default render is unchanged.

**Look at:** `oblique-groups.jpg` (allotment huts and garages, scene C, z19), `sheet.jpg` (scene D: dense blocks stay in plan).
