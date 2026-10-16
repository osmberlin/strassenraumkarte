# LA 23 — mapped roof colours

The DB was re-imported on 2026-10-16 with `roof:colour` and `building:colour` (added to `osm_import.lua`). In the Schillerkiez, 455 of 6014 buildings have `roof:colour` and 233 have `building:colour`, mostly as `#rrggbb`.

A first, literal mapping broke the mission (left column of `roofs.jpg`). `building:colour` turned the Herrfurthplatz church fully red. `roof:colour #4A5624` turned whole courtyard blocks sage. Grey tags pulled the white volumes towards grey.

The rule now is that mapped data decides **where** the accents go, within the plan's vocabulary:

- Only `roof:colour` is used. `building:colour` is the facade colour, which a plan view does not show.
- **Red**: saturated red, orange or brown, with saturation (max − min) / max ≥ 0.3. Gets the terracotta accent only on small non-landmark buildings (< 600 m²).
- **Green**: a saturated green roof gets a very pale sage tint `#E6E9DD`.
- **Plain**: every other parsable value (greys, whites, khaki `#948975`, taupe `#A29893`, blues) renders as a white volume, and such a building is never picked for the random red accent.
- Untagged buildings keep the old rules.

Unit test `roof_tone_classes` in `style_la_extra.rs`.

**Look at:** `roofs.jpg` (top: Herrfurthplatz, bottom: courtyard blocks in scene D; left: literal mapping, right: now).
