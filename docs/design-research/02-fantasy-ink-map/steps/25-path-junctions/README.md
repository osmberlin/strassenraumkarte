# Ink 25 — path junctions

Park and footway paths are drawn as double lines (a wide ink casing, then a narrower paper fill). Until now each path was drawn in one go, casing then fill, so at a meeting point the round cap of one path's casing sat on top of the other path's paper. Every junction showed a pill-shaped overlap instead of a clean meeting of lines.

## What changed

- **Two passes over all paths** (`style_ink.rs`, the paths block): first every casing, then every paper fill. A path's paper now erases the casing of each path it meets, so junctions read as one plan drawing: the lines run into each other and stop at the open side.
- **Casings in their own layer:** the casings are drawn into a transparent layer and composited once at the ink alpha (0.75). Drawn path by path, the translucent ink would darken where two casings overlap at a junction.
- Paper is one colour, so the fill order (by width) makes no visible difference and needs no grouping.
- Sidewalks and crossings are still skipped. Paths that end on a carriageway or a plaza still open into it: their paper erases the outline where they meet.

## Look at

- `junctions-before-after.jpg`: the Tempelhofer Feld / Hasenheide junction cluster at z19, before (left) and after (right). The pill caps are gone.
- `before-after.jpg`: this step against step 24 (scenes A–D). Only the path junctions differ.

## Checks

- `cargo test --release`: 21 pass, 4 ignored (unchanged).
- `seam_check.sh ink`: 0.001 % of pixels differ (limit 0.1 %).
- Scenes a, c, f and the z17 crop checked by eye: no pill caps at junctions, paths open into the plaza in scene a.
