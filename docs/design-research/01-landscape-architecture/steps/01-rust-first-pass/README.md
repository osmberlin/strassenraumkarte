# LA 01 — first pass in Rust (`srk-render --layers la`)

First rendering of the landscape-architecture style **directly from PostGIS** (no image post-processing), in [`rust/srk-render/src/style_la.rs`](../../../../../rust/srk-render/src/style_la.rs).

- Palette from the Pinterest swatch pin (`#EAE9E3` paper, `#CBD4BC` lawn, khaki/olive crowns `#85835F … #5F5E3E`).
- Trees: one symbol variant per genus (disc + ring + dot, radial branches, scalloped two-tone; star for conifers), translucent, multiply shadow to SE. Crown size from `diameter_crown`.
- Buildings from `building` (not the dissolved parts): white, crisp outline, three-step SE shadow scaled by height, ~10 % light grey, red only on small buildings.
- Lawn: world-anchored watercolour mottling (seamless across tiles); shrub beds as dabs.

**Look at:** crowns are too dark and too olive compared to the board; red roofs still land on the church parts and on some long buildings; carriageway and pavement tones are too close.
