# Exploration 01 — Landscape-architecture plan

![Current Rust rendering of the four scenes](current.jpg)

_Current state: rendered by `srk-render --layers la` directly from PostGIS ([`style_la.rs`](../../../rust/srk-render/src/style_la.rs)). Iterations with before/after notes are in [`steps/`](steps/). The first image-processing mockups are kept in [`mockups/`](mockups/) for comparison._

## Mission statement

> **The Straßenraumkarte should read like a site plan that a landscape architect drew for the street, not like a map.**
>
> The open space is the subject: lawns, planting, trees, paving and play areas are drawn with care and in soft, earthy, slightly pastel colours, and every tree is a small drawing of its own. Buildings recede into a calm, crisp contrast: white or light grey volumes with sharp dark outlines and a cast shadow, with an occasional red roof as an accent. The result must be produced **directly by the data pipeline** (SQL + QGIS) from OSM data, at every zoom level, without manual post-processing.

What this means in one sentence per element:

- **Ground**: the plan is about surfaces. Each surface (lawn, meadow, sand, paving, asphalt) has its own muted tone and a light grain, so it looks drawn and not filled.
- **Trees**: drawn symbols with a scalloped crown, a lit side, a shadow side, a trunk dot and a cast shadow. Single trees stay readable; woodland is a mass of overlapping crowns, not a green blob.
- **Buildings**: the "paper white" of the plan. Crisp outline, flat light fill, parts separated by thin lines, a hard shadow towards SE. Only a small share has a terracotta roof.
- **Streets**: warm grey, quieter than today, so the green and the people's space carry the picture. Cars, markings and furniture stay, but in greys.
- **Colour budget**: no saturated colour anywhere except small accents (red roofs, play equipment, water).

## Implemented so far (Rust)

![Richardplatz and Körnerpark](current-ef.jpg)

Roofs with and without (`SRK_ROOFS=off` left, default right): LA [A Herrfurthplatz](../roof-shapes/compare-la-a-herrfurthplatz.jpg) · [B Schillerpromenade](../roof-shapes/compare-la-b-schillerpromenade.jpg) · [E Richardplatz](../roof-shapes/compare-la-e-richardplatz.jpg) · [F Körnerpark](../roof-shapes/compare-la-f-koernerpark.jpg); ink [A Herrfurthplatz](../roof-shapes/compare-ink-a-herrfurthplatz.jpg) · [B Schillerpromenade](../roof-shapes/compare-ink-b-schillerpromenade.jpg) · [E Richardplatz](../roof-shapes/compare-ink-e-richardplatz.jpg) · [F Körnerpark](../roof-shapes/compare-ink-f-koernerpark.jpg).

Tree legend: [`steps/20-legend-water-names/legend.jpg`](steps/20-legend-water-names/legend.jpg) (regenerate with `docs/design-research/tools/la_tree_legend.sh out.png`). More: [`showcase-z17.jpg`](showcase-z17.jpg) / [`showcase-z18.jpg`](showcase-z18.jpg) (whole Schillerkiez), [`map-sheet-schillerkiez.jpg`](map-sheet-schillerkiez.jpg) (as a plan sheet with title block, north arrow and scale bar), iterations in [`steps/`](steps/).

| Element | Implementation |
| --- | --- |
| Paper / ground | `#EAE9E3`, fine world-anchored paper grain |
| Lawn, meadow | `#CBD4BC` / `#C2C5A6`, large-scale watercolour mottling, darker bled rim along the edges |
| Shrub beds, tree pits | `#BDBBA4` with soft dabs and a darker edge |
| Water | `#A9BEBD`, blurred darker band along the banks (watercolour depth), crisp bank line |
| Woodland | crowns on a world grid + mapped trees inside woods, drawn opaque into one layer and composited at 80 % → even canopy |
| Streets | carriageway `#C9C5BA` with kerb line, sidewalks `#F1F0EB` with joint ticks (z19+), pedestrian areas with a joint grid (z19+), cycleways `#D3A796`, parking bays with white lines, road markings pulled towards grey |
| Buildings | white `#FBFAF7`, crisp `#4E4D46` outline, blurred SE shadow scaled by height, `building:part` as faint lines; outbuildings light grey; red (`#C98C7A`/`#B98270`) only on ~¼ of small homes. Mapped `roof:colour` ([step 23](steps/23-mapped-roof-colours/)) decides where accents go: saturated red → terracotta on small non-landmark buildings (< 600 m²), saturated green → pale sage tint, any other value → white and never a random red. `building:colour` is imported but ignored (facade colour). Databases imported before 2026-10-16 lack the column; the renderer then keeps the rules above |
| Trees | **per genus** (step 19/20, [legend](steps/20-legend-water-names/legend.jpg)): Tilia fine-scalloped dome, Acer lobes + veins, Betula airy stipple, Quercus cloud of sub-crowns, Platanus large disc + ring, blossom trees ring of white dots, Salix fringe, Carpinus/Fagus double scallop, Robinia/Fraxinus radial, conifers star; fixed tone and default crown size per genus when `diameter_crown` is missing. Only ~500 of 11 500 trees carry `genus`. **Street trees** without genus: one symbol and tone per street (nearest named road), so rows read as rows. Park trees: generic symbols by id. Translucent, NW-lit radial gradient, blurred SE shadow |
| Pitches | procedural white line markings from `pitch_markings` |
| Railways | gravel bed, two rails, sleepers from z18; below streets/bridges |
| Bridges | `bridge` polygons: soft SE shadow (grows with `layer`) onto rails, water and roads below, light deck, crisp parapet outline over the street surface; street areas drawn ground level → bridge → raised |
| Details | hedges, walls, fences, embankment combs. Benches with backrest line (side opposite `direction`), picnic tables, table tennis with net, bins, lamps; bicycle stands as a row of U-shapes (count from `capacity`) across the nearest street; drinking water, street pumps and fountains as water circles, fountain basins with a double rim |
| Play | sandpits with timber edge, water basins/channels, slides (white chute, ladder rungs), swing frames with seats, seesaws, springers, rotators, white structures with outline (plan cross on playhouses/platforms) |
| Labels | street names (Avenir Next Medium, spaced caps, z17+), area names (Avenir Next Demi Bold, spaced caps), water names (Avenir Next italic, bank colour, z17+) |
| Not available | parked cars: the QGIS layer reads `data/parking/street_parking_points_processed.geojson`, which is not generated in this checkout and has no table in PostGIS — skipped |
| Roofs | from `roof_shape.sql` (z17+): faint facet tones by NW light, ridge hairlines (`SRK_ROOFS=off` to disable) |

Variant: `SRK_LA_PALETTE=vivid` — saturated greens of modern competition plans for lawns, beds and crowns (see [step 11](steps/11-vivid-palette-variant/)).

## Style attributes

Full evidence, measured colours and 25 references: [research-notes.md](research-notes.md).

### Palette (first proposal)

Used in the mockups; starting point for the QGIS style. Derived from the measured historic plans in the research notes, shifted lighter so the street-space detail stays legible.

| Element | Today (approx.) | Target | Notes |
|---|---|---|---|
| Paper / unbuilt yards | `#ececec` | `#ebe7dc` | warm, not grey |
| Lawn | `#cedeb9` | `#cdd2ad` | sage-pastel, light grain |
| Meadow / rough grass | — | `#bcc29b` | darker, broken, dabs |
| Tree crowns (mix per tree) | `#93bc7b` translucent | `#9caa80`, `#8d9e74`, `#b1b58b`, `#a8a479`, `#7f9270`, occasionally `#c3b386` | vary per tree ID, 85 % opacity |
| Crown outline / branches | none | crown colour × 0.6 | thin scalloped line, 5–7 radial strokes |
| Sand, paths, playground | `#e3e1bb` | `#e0cfa7` | ochre |
| Sidewalk / paving | `#e9e3dd` | `#e2dbcd` | optional joint pattern at z19+ |
| Carriageway | `#a0a09d` | `#bdb7ab` | warm grey, lighter than today |
| Water | `#b4b4f0`-ish | `#a7c2bf` | muted teal, darker edge |
| Building fill | `#e9d8d8` pink | 55 % `#fbfaf6`, 20 % `#e2dfd8`, 12 % `#cfccc5` | white / light grey mix |
| Roof accent | — | `#cf9377`, `#bb7f66` | ~10 % of building parts, never a whole block |
| Building outline | soft shade | `#2e2d2b` | crisp, heaviest line in the plan |
| Shadows | blurred grey | multiply 20 % (buildings), 35 % (trees), towards SE | fixed sun azimuth |

### Line hierarchy

Building outline (heaviest) → tree crown outline → kerbs, walls, fences → road markings → paving joints (lightest, only at z19+). Lines are dark warm grey, never pure black.

### Tree vocabulary

1. **Deciduous solitaire**: scalloped circle (8–13 bumps, ±7 % radius), lighter cap offset to NW, darker rim, 5–7 radial branch strokes, trunk dot, offset shadow.
2. **Woodland / tree group**: many overlapping crowns at 85 % opacity, varied hues, one shared shadow.
3. **Street tree row**: same symbol, slightly smaller and more uniform in colour.
4. **Conifer** (if tagged `leaf_type=needleleaved`): star/spiky outline, darker.
5. **Shrub / hedge**: irregular blob band with darker outer edge, no branch strokes.

### Buildings

Light fill, crisp outline, building parts separated by thin lines (we already have `building_parts_dissolved_height`), hard cast shadow (we already have `building_shade`). `roof:colour` from OSM where tagged; otherwise a deterministic pseudo-random pick by building ID, with red only on small parts.

## Mapping to the current pipeline

| Target element | Existing source (QGIS layer / SQL) | Change needed |
|---|---|---|
| Tree symbols | `tree crown`, `trunk`; `data/processing/sql/tree.sql` | Replace the translucent disc with a geometry-generator or SVG-based crown: scalloped polygon from crown radius (SQL: `ST_Buffer` + sine-perturbed ring, seeded by `osm_id`), highlight and shadow as offset copies. Colour picked by `osm_id % n` or by `genus`/`leaf_type`. |
| Woodland masses | `landuse` (forest/wood), `scrub (width shade)` | Fill polygon with seeded point grid (`ST_GeneratePoints` with seed), each point rendered as a crown symbol. |
| Building fill + outline | `building_parts_dissolved_height`, `building_lines` | New palette; outline width up; per-part colour from `roof:colour` or hash. |
| Building shadow | `building_shade` | Keep geometry, change to multiply with fixed SE offset, harder edge. |
| Lawn grain | `landuse surface` | Raster fill / texture at low opacity, or QGIS noise via shapeburst + random marker fill. |
| Roads, sidewalks | `highway_area`, `path (way, fill)` | Palette only. |
| Cars, markings, furniture | `parking cars`, `road_marking_*`, `feature_*` | Desaturate to warm greys (except play equipment). |

## Open questions

- How do tree symbols degrade at z16–17 (crown < 4 px)? Probably plain soft discs below z18.
- Pastel vs. modern saturated olive: the research shows modern Photoshop plans are often more saturated. We start pastel (historic plans) and test both.
- Do we want paper grain in the tiles? It tiles visibly unless it is world-anchored.
- Which sun azimuth and shadow length? Proposal: azimuth 315° (light from NW), one value for the whole map.
- Labels: today's sans-serif street names fit; an optional spaced-capitals style for park names.

## AI target-picture prompts

No image-generation model was available in the session that set this up, so the mockups are procedural. To compare with an AI restyling, feed a scene from [`../scenes/`](../scenes/) to an image model with this prompt:

> Redraw this map tile as a hand-rendered landscape architecture site plan, top-down orthographic view, exactly the same geometry. Earthy pastel palette: sage lawn, ochre sand paths, warm grey asphalt, cream paper background with subtle grain. Every tree as an illustrated plan symbol: scalloped crown outline, lighter top-left, darker rim, fine radial branch lines, small trunk dot, soft cast shadow to the bottom-right; woodland as overlapping translucent crowns in varied olive and sage tones. Buildings as crisp white and light grey volumes with sharp dark outlines and a hard shadow to the bottom-right; a few small buildings with terracotta red roofs. No perspective, no 3D, no text changes, no new objects.

Save results into `mockups/ai/` with the model name in the file name and commit only the ones worth keeping.

## How the mockups were made

1. [`tools/make_scenes.py`](../tools/make_scenes.py) stitches four 4×4 z19 tile blocks (see [`../scenes/`](../scenes/)).
2. [`tools/classify.py`](../tools/classify.py) classifies pixels by colour into ground classes (building, road, sidewalk, sand/path, lawn, tree, water, other).
3. [`tools/restyle_mockup.py la`](../tools/restyle_mockup.py) recolours the ground classes (keeping the source luminance as detail), splits building blocks into parts using shade edges, places tree crowns by disc packing inside the tree mask, and draws everything in the target style.

Known mockup artefacts that are **not** part of the target: ragged building edges where the source had inner shadows (scene D), building parts that are split wrongly, playground equipment rendered grey.

## References

- [research-notes.md](research-notes.md): attributes, measured palette, 25 references, production techniques, procedural precedents.
- `references/web/`: downloaded reference images (local only, not committed; see [references/README.md](references/README.md)).
- `references/user/`: place for Tobias's collected screenshots (local only).
