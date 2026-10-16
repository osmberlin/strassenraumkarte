# Ink 14 — forest as one cloud silhouette

- Woodland is no longer a heap of outlined crowns. Three passes: (1) heavy outline of every crown, (2) paper fill of every crown on top (`FillRule::Winding` — with EvenOdd the overlaps become holes and the outlines shine through), (3) a light lower-right arc and a few shading strokes per crown. Only the outer silhouette stays heavy — the classic forest of fantasy maps.
- Mapped `natural=tree` points inside a wood join the silhouette instead of being drawn one by one.
- Coarser forest when zoomed out: scatter cell and crown size grow by √2 per zoom level below z19.

**Look at:** `forest.jpg` (Hasenheide edge, z19 left / z17 right), compare with step 13.
