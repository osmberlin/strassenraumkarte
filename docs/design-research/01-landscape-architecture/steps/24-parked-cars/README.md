# LA 24 — parked cars (variant `SRK_CARS=on`)

Tobias wanted parked cars as an on/off variant. The data now exists: the TILDA parking pipeline writes `street_parking_point`, one point per parked vehicle with `type` (`motor_vehicle01/02`, `hgv`, `bus`, `taxi`, `emergency`), `colour`, `angle` (bearing of the long axis, as the QGIS SVG rotation) and `layer`. In the Schillerkiez that is about 13 000 vehicles. Before this step the LA README listed cars as "not available".

**Look at:** `cars-compare.jpg` (top: Allerstraße at z19, bottom: z20; left without, right with cars). `sheet.jpg` / `sheet-ef.jpg` are rendered with `SRK_CARS=on`.

## How cars look in a site plan

Competition site plans draw parked cars as CAD blocks: a rounded rectangle in white or light grey, a thin dark outline, sometimes the cabin and the glass, never a photo-real car and never a saturated colour. That is what `style_cars.rs` (`draw_la`) draws:

- **Footprint** 4.4 × 1.85 m (taxi 4.6 m, vans/`hgv` and emergency 4.9 × 2.0 m, bus 11.5 × 2.55 m), rotated by `angle`, corner radius 0.45 m. Parallel rows are 5.2 m apart in the data, so cars never overlap.
- **Fill**: near white `#FBFAF7` mixed 22–28 % with the mapped `colour`, which is first desaturated by 70 %. Red and blue cars become a faint warm or cool grey, dark cars a light grey. The street stays calm.
- **Outline**: the building ink `#4E4D46` at 75 % (45 % at z17), 0.45–0.9 px.
- **Shadow**: a soft shadow 0.55 m towards the SE, the same NW light as buildings and trees, blurred and multiplied at 32 % (22 % at z17).
- **Details from z19**: a slightly darker cabin (roof) with darker glass bands for the windscreen and the rear window; vans and emergency vehicles have the cabin up front, the bus gets two roof units.
- **Layer order**: after road markings, before furniture and trees, so the translucent crowns overhang the cars, as in a plan.
- From **z17**, where a car is a 6 × 2.5 px light dash with a faint outline. Rows read as the parking strip, not as single cars.

## Default: off

`SRK_CARS` stays **off** by default. Site plans show cars only where parking is the subject; here, about 13 000 light blocks fill every kerb and pull the eye away from the open space, which the mission puts first. The variant fulfils the mission line "Cars, markings and furniture stay, but in greys" for anyone who wants the parking supply visible (viewer layer `la-cars`).

## Checks

- `SRK_CARS=on seam_check.sh la`: mean 0.031 %, worst 0.34 % at z19; z18 mean 0.025 %. Without cars the same check gives 0.050 % / 0.57 %, so cars add no seams. The shadow is a blurred layer over the whole buffer, like the building shadows.
- `cargo test --release` green (two new unit tests in `style_cars.rs`: world-anchored seeds, footprints shorter than the 5.2 m row spacing).
- Databases without `street_parking_point` render as before (the table is checked with `to_regclass`).
