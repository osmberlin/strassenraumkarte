# Ink 27 — parked cars become carts (variant `SRK_CARS=on`)

Tobias: "for our fantasy style think about how to translate cars — carriages with dragons in front? no idea…". The data is `street_parking_point` from the TILDA parking pipeline: one point per parked vehicle with `type`, `colour` and `angle` (bearing of the long axis), about 13 000 in the Schillerkiez.

**Look at:** `cars-compare.jpg` (top: Allerstraße at z19, bottom: z20 with horses and a dragon; left without, right with). `options.jpg` compares the two drawings that were tried. `sheet.jpg` / `sheet-ef.jpg` are rendered with `SRK_CARS=on`.

## Two options, judged on renders

1. **Upright side view** (chosen). Every vehicle becomes a small cart drawn standing up, like the trees, benches and street lamps: seen from the south, paper-filled, painted north → south in the same list as the other upright things, so a tree in front hides the cart behind it.
2. **Plan view from above** (`SRK_INK_CARS=plan`, kept as a switch but not recommended): the cart as a box along `angle` with wheels sticking out, hoops on the canvas and shafts. It shows the parking geometry exactly, but it reads as rows of boxes, and a horse from above is an unreadable oval. It adds nothing a fantasy map would draw.

The upright carts read as carts at once, and the rows along the kerb look like a market street. That fits the mission ("everything that stands up is drawn standing up").

## The vocabulary

- **`motor_vehicle01` → open cart** with a load of sacks or barrels (seeded). **`motor_vehicle02` → covered wagon** with a canvas tilt, hoops and fine shading on the near side. **`hgv` → a longer covered wagon.** **`taxi` / `emergency` → a small coach** with windows, a roof rail, the driver's bench and a lantern. **`bus` → a long stagecoach.** About half of the cars become carts and half wagons, as the two car types split in the data.
- **Facing:** the side view faces left or right after the east–west part of `angle`. On diagonal streets the side view is foreshortened (down to 60 %). Where the vehicle axis runs north–south the cart is seen **from its end**: wheels edge-on at both sides, the canvas arch with a dark opening, or the load. This keeps the columns on north–south streets narrow.
- **Teams:** most carts stand with their shafts resting on the ground, because the horses are in the stable. A cart gets a **horse** in the shafts (40 %) only where the kerb in front is free: no other vehicle within 4.6 m ahead in a ±2.2 m band. That happens at the ends of parallel rows and in perpendicular bays, where the horse stands on the pavement. With at least 5.6 m free, **6 % get a small dragon** instead: folded bat wings with ribs, a horned head, a tail that curls up (never under the cart), a curl of smoke. End views and z18 carts get no team.
- **Zoom:** z19+ full detail. **z18**: outline, bed and wheels only, a lighter pen, no team, so the kerb does not turn into a dark band. **z17 and below**: no cars; a cart would be a 6 px smudge.
- **Accent:** `SRK_ACCENT=cars` draws all carts, teams included, in the vermilion accent ink and switches the cars on by itself. The parking supply then shows as red rows.
- **Seam safety:** each vehicle's seed comes from its world position (decimetre grid), not from the table id. The free-kerb test uses world coordinates of all vehicles in the query margin (40 m, far more than the 14 m search), so every metatile layout makes the same choice.

## Default: off

`SRK_CARS` stays **off** in the ink map. The mission's rule table says cars "break the fiction and clutter the drawing", and the plain map should stay the one a fantasy reader expects. The carts are a playful variant, `ink-cars` in the viewer, or the accent `SRK_ACCENT=cars` to show parking pressure in a drawing that otherwise has none.

## Checks

- `SRK_CARS=on seam_check.sh ink`: z19 mean 0.003 %, worst 0.02 %; z20 mean 0.008 %, worst 0.13 %; z18 mean 0.002 % (limit 0.1 % mean).
- `cargo test --release` green.
- A first render had covered wagons without a tilt: `sin(π)` is slightly negative in `f32`, and its `powf` gave NaN, which drops the whole path. Clamped to 0.
