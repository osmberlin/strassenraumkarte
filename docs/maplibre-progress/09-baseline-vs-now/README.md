# 09 — Baseline versus now

Columns: QGIS (new style) · vector at the start of this work (step 00) · vector now (after
step 14). This folder is the summary view and is regenerated when a later step moves the
numbers. Step 14 regenerated the montages; the middle column is still the step-00 picture from
the earlier montage, so the "start" pictures are the original ones.

The QGIS reference changed in step 14 (main 05991fe brought the new style: parked cars, tree
variants, kerbs, one-way arrows). The table therefore has the step-13 numbers twice: against the
old style, and against the new one.

| Location | Start (step 00, old style) | Step 13 (old style) | Step 13 (new style) | Step 14 (new style) |
|---|---:|---:|---:|---:|
| Intersection, z18 | 11.8 % | 3.0 % | 5.8 % | 4.3 % |
| Dense trees, z18 | 69.5 % | 1.9 % | 4.3 % | 4.1 % |
| Dense housing, z17 | 18.1 % | 5.2 % | 5.8 % | 4.4 % |
| Residential street, z19 | 11.4 % | 2.4 % | 3.1 % | 2.7 % |
| Playground, z18 | 17.8 % | 3.4 % | 3.4 % | 3.1 % |
| Park / pools, z17 | 21.4 % | 3.4 % | 4.0 % | 3.8 % |
| Courtyard furniture, z19 (added in step 10) | 6.5 % | 3.4 % | 7.9 % | 7.6 % |
| Sett street, z20 (added in step 12) | — | 2.4 % | 8.9 % | 5.0 % |
| **Mean of the eight** | | | **5.4 %** | **4.4 %** |

The number is the share of pixels that pixelmatch flags (threshold 0.1) between the QGIS raster
pane and the vector pane; the map controls in the QGIS pane account for about 0.2 %. The "start"
column was measured with an earlier harness, so compare within a column only. The step 13 and
step 14 columns come from the same harness.

What made the difference, roughly in order of effect:

1. Real drop shadows and the QGIS building stack (`fill-layer-blur`, step 02).
2. Tree crown textures, flattened before fading (`symbol-layer-opacity`, steps 03–04).
3. Inner shadows along carriageways and water (`fill-layer-blur-mode`, step 03).
4. Port bugs: scale gates one zoom late, dash lengths, icon aspect and colours, label
   colours, layers QGIS does not have, parking spaces as carriageway (steps 03, 05, 06, 10).
5. Landuse textures (step 07), sub-pixel line ink (step 08), ground-sized rotated textures
   (step 12), marker rows (step 11), multiplied surface textures (step 01).
6. Parked cars, tree shrubs and variants, kerb shade and one-way arrows (step 14). The mean
   against the new style fell from 5.4 % to 4.4 %, mostly at Sett street (8.9 → 5.0 %) and
   Intersection (5.8 → 4.3 %).

The score understates two steps: thin lines (step 08) and texture rotation (step 12) look
clearly closer but hardly move it, because QGIS output is softer (resampled, JPEG) and the
textures are only 6–12 % opaque.

![Intersection](./intersection.jpg)
![Dense housing](./dense-housing.jpg)
![Residential street](./parking-street.jpg)
![Park](./park-water.jpg)
![Dense trees](./dense-trees.jpg)
![Playground](./playground.jpg)
