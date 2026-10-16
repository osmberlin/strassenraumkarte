# Ink 20 — bridges, civic landmarks, street furniture, oblique shadows

- **Bridges** (`bridge` table): the deck is filled with paper right after the railways, so rails and water below are hidden; after the streets, heavy parapet lines are drawn along the long sides of the deck (edges parallel to the `ST_OrientedEnvelope` axis) with flared wing walls at both ends — the old-map bridge sign. A south-facing parapet gets a short hatched shadow.
- **Landmarks besides churches**: `building=school|kindergarten` get a small bell turret, `civic|public|townhall` a clock tower with dome and flag (scene B). One icon per building, on its largest polygon (≥ 250 m²), on the ridge or well inside the footprint, from z17; painted north → south together with the spires.
- **Street furniture glyphs at z19+**, upright like trees and sorted with them: street lamps (post + lantern), street pumps (`water_well`, the Berlin Plumpe with its lever), drinking water, fountains (basin with jets, also for fountain areas — Körnerpark), advertising columns (Litfaßsäule), memorials/artworks (obelisk), clocks, flagpoles.
- New accent `SRK_ACCENT=water`: drinking water, pumps and fountains in vermilion, shown from z17.
- **Oblique variant** (`SRK_INK_OBLIQUE=freestanding`): lifted buildings cast a hatched shadow towards the east-north-east (light from the south-west, matching the shaded roof half); drawn before all buildings so they cover it.

Code: new `style_ink_extra.rs` (bridges, landmark icons, furniture glyphs).

**Look at:** `bridge.jpg` (Hertabrücke over the Ringbahn, z19), `sheet-ef.jpg` (fountain in Körnerpark), `oblique.jpg` (scene C, shadows of the allotment huts).
