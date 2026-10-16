# Labels in `full-approx` (QGIS PAL parity)

Branch `worktree-agent-adac79d3efbfe617b` (fast-forwarded to `d0e66ad`, the PR branch head, then the label commit on top).

## What changed

- New module `rust/srk-render/src/labels_full.rs`: queries the label sources, builds candidates, resolves conflicts and paints them with resvg in one SVG per metatile.
- `layers.rs`: one call at the end of `render_full_approx`, just before `write_meta_cores`.
- `main.rs`: `mod labels_full;`.
- `Cargo.toml` / `Cargo.lock`: direct dependency `ttf-parser = "0.24"` (already in the lock at 0.24.1) for glyph advances, so text boxes match the rendered width.

Nothing else is painted differently. Other layers (trees, ground, streets, buildings, symbols) are untouched.

## Layers and rules (from `style/strassenraumkarte.qgz`)

Scale denominators use QGIS at 96 dpi: `scale = 591657527.6 / 2^z` for 256 px tiles (z17 = 4513, z18 = 2256, z19 = 1128, z20 = 564). Rule ranges are inclusive. Scale gates were checked against the reference: `label_highway` z17 (low) and z18/19 (high), landuse z14–18, the "Schillerkiez" quarter at z16.

| QGIS layer | table / filter | visible at | size, colours (text / halo, opacity), halo | placement |
| --- | --- | --- | --- | --- |
| `label_highway` | zoom = `low` (1:4000–8000) | z17 | 10 pt; 221,221,221 / 168,168,167 @0.75, 2 pt | curved, on line, mid-length of the line; fit check by text length |
| `label_highway` | zoom = `high` (1:1000–4000) | z18, z19 | same; text opacity 50 % below 1:2000 (z19) | same |
| `label landuse` primary (forest, park, recreation_ground, wood) | 1:2000–64000 | z14–z18 | 10 pt; 168,168,167 / 225,227,189 @0.75 | centroid if inside, else point on surface; box must fit the polygon; hidden when area/scale < 25 above 1:6000 |
| `label landuse` secondary (cemetery, dog_park, farmland, garden, playground) | 1:2000–4000 | z18 | as primary, text opacity 0.67 | as primary |
| `label water body` | 1:2000–60000 | z14–z18 | 10 pt; 171,165,216 / 205,203,234 @0.75 | as landuse |
| `label_waterway` | 1:2000–16000 | z16–z18 | 10 pt; stream/ditch/drain and others swap text and halo colours; hidden < 250 m, and for non-river/canal above 1:6000 | curved (no offset yet) |
| `place_polygon` / `place_node` rules | `city_block`, `farm`, `isolated_dwelling`, `square` 1:1000–8000 (z17–19); `allotments`, `hamlet`, `islet`, `neighbourhood`, `quarter` 1:4000–16000 (z16–17); `island`, `suburb`, `village` 1:16000–64000 (z14–15); `borough`, `town` 1:32000–64000 (z14); `city` 1:64000–128000 (z13) | as listed | 10 pt; 168,168,167 / 168,168,167 @0.75 (see below) | centred on the point or polygon anchor; `$area/scale > 0.75` for the first rule |
| `housenumber` | `addr:housenumber`, 1:0–1000 | z20+ | 7.5 pt DejaVu Sans; 183,183,183 / 216,213,213 @0.75, 2.5 pt | centred on point |

Priorities: place names 7, everything else 5 (higher wins conflicts).

## Font

The project names DejaVu Sans Condensed (street, area, place) and DejaVu Sans (house numbers). DejaVu is not installed on this Mac, so the module uses DejaVu when it is present (`fontdb`, same family names) and falls back to Arial. The reference most likely used DejaVu Sans Condensed: the measured width of "Schillerkiez" (~69 px) matches DejaVu Condensed (68 px) slightly better than Arial (67 px). Glyph outlines differ, so this is the largest remaining source of label mismatch. On a machine with `fonts-dejavu-extra` installed the module picks the reference face automatically.

## Measured choices (deviations from the project values)

- Place-name colours: the reference glyphs read as grey on a grey halo. Box MAE over the "Schillerkiez" box was 16.4 with text = halo = 168,168,167, against 17.5 with the project's text 215,216,197 on 168,168,167 and 20.0 with the colours swapped. The measured colours are used.
- Polygon anchors: centred on the anchor, no vertical shift. A "below the anchor" variant looked plausible from one reading but scored worse on the park box (16.4 vs 15.8) and was reverted.
- Halo: a stroke of 2 × buffer radius (`paint-order: stroke`), opacity from the buffer.

## Seam safety

16 tiles at z18 (4×4 block) rendered with `--metatile 1 --gutter 1` and with `--metatile 4 --gutter 1`: all identical (0 differing pixels in every tile). Candidate geometry is built from the whole feature in world coordinates, the query window is 400 m larger than the metatile, and conflicts are resolved by priority and a world-anchored key.

## Numbers (manifest-full, same build, pixelmatch ratio)

The "before" column comes from the same branch with the single call commented out (not the older shared baseline, which was rendered on an earlier build and differs by ±0.1 on the unlabelled tiles).

| Tile | Label content | Before | After | Delta (pp) |
| --- | --- | ---: | ---: | ---: |
| 15/17606/10752 | density z15 | 25.61 | 25.01 | -0.60 |
| 15/17605/10752 | intersection parent z15 | 23.17 | 23.17 | 0.00 |
| 16/35212/21505 | density z16 | 20.18 | 20.18 | 0.00 |
| 16/35211/21505 | intersection z16 ("Schillerkiez") | 19.26 | 18.66 | -0.60 |
| 19/281691/172046 | intersection z19 (street, 50 %) | 15.96 | 15.61 | -0.35 |
| 17/70422/43011 | intersection z17 (park "Herrfurthplatz") | 15.75 | 15.47 | -0.28 |
| 18/140845/86023 | intersection z18 (curved street) | 14.92 | 14.98 | +0.06 |
| 17/70425/43010 | density peak z17 | 14.61 | 14.61 | 0.00 |
| 18/140851/86021 | density z18 | 10.82 | 10.69 | -0.13 |
| 20/563382/344092 | intersection z20 (no label layer active) | 9.36 | 9.36 | 0.00 |
| **mean** | | **16.965** | **16.774** | **-0.19** |

The z18 intersection tile changes by 543 pixels in the label box; 260 move closer to the reference and 282 further away, so the +0.06 is glyph-level noise.

Before/after crops: `labels.jpg` (reference | before | after, 3× nearest).

## Tests

- `cargo test --release`: 21 passed, 4 ignored (pre-existing ignores). New unit tests in `labels_full::tests`: separating-axis overlap, point-in-ring, scale gates by zoom, conflict order by priority then world key.
- `cargo build --release` has no warnings from the new module.

## Remaining gaps

1. Font fallback on macOS (see Font). Glyph outlines in the label boxes still show in the diff.
2. Placement is a simplified PAL: no candidate search or curvature limit for curved labels, no building obstacles, one label per line segment at the middle of its length. Labels that QGIS would move to a free position may differ.
3. Not covered: `feature_node` / `feature_polygon` labels (bicycle capacity, hydrant diameter; the "12" with a circle symbol at z20 appears to come from these), `trunk` labels (tree numbers, z20 "8"), label_waterway offsets above streams (half waterway width).
4. Not verified against the reference because no sample tile contains them: `housenumber` (the z20 test tile has no housenumber rows; the 1:1000 gate is from the rule), water body names, waterway names, secondary landuse, and the C–E place rules. The gates are implemented as read from the project, but they are unchecked.
5. Not a label issue but visible in both baseline and new renders: black blobs scattered over the z15 density tile (`15/17606/10752`), mostly at crossings. They look like a symbol layer, not text; the reference has none.
