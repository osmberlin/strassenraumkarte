# Ink 01 — first pass in Rust (`srk-render --layers ink`)

First rendering of the fantasy ink style **directly from PostGIS**, in [`rust/srk-render/src/style_ink.rs`](../../../../../rust/srk-render/src/style_ink.rs).

Decision for houses (Tobias: "muss nicht 3D sein"): **plan view with a hint of volume** — roof hatched along the slope (perpendicular to the long axis of `ST_OrientedEnvelope`), ridge line where the footprint is roughly rectangular, and a narrow south facade band with window ticks on every south-facing edge. Only landmarks (church) and trees stand up. Everything upright is painted north → south.

- Ground: carriageway outline + sparse stipple, park paths as double lines, lawn tufts, shrub loops, sand stipple, water with shore ripples and wave strokes.
- Accent: playgrounds in vermilion (outline, 45° hatch, light wash, equipment glyphs) — the rest stays ink.
- All noise and scatter is world-anchored, so tiles join seamlessly.

**Look at:** the woodland in scene C; the playgrounds in B and D; facade bands along the blocks. To fix: the church gets two spires (one per church polygon), lawn tufts read as dots at z19.
