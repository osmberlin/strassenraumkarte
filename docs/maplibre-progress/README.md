# MapLibre port — visual progress

One folder per step, each with side-by-side screenshots at the compare locations
(`vector/locations.ts`) and a short README saying what changed and what to look at.
The QGIS raster tiles are the reference.

| Step | What |
|---|---|
| [00-baseline](./00-baseline/README.md) | State of the port before renderer patches |
| [01-layer-blend-multiply](./01-layer-blend-multiply/README.md) | First MapLibre patch: `fill-layer-blend: multiply` for surface textures |
| [02-layer-blur-shadows](./02-layer-blur-shadows/README.md) | Second patch: `fill-layer-blur` → soft building shadows, QGIS building stack |
| [03-inner-shadows-and-assets](./03-inner-shadows-and-assets/README.md) | Inner shadows (`fill-layer-blur-mode`), tree crown textures, correct icons |
| [04-flattened-trees-and-water](./04-flattened-trees-and-water/README.md) | `symbol-layer-opacity` for tree crowns, baked crown shadows, pool and water edges |
| [05-road-marking-dashes](./05-road-marking-dashes/README.md) | Dash lengths in ground metres, marking opacity; notes on MapLibre vs QGIS dashes |
| [06-scale-gates-labels-playground](./06-scale-gates-labels-playground/README.md) | Scale→zoom off-by-one, QGIS label colours, playground and marking colour fixes |
| [07-landuse-textures](./07-landuse-textures/README.md) | Grass, gravel, sand and other class textures on landuse |
| [08-hairline-coverage](./08-hairline-coverage/README.md) | Patch: sub-pixel lines fade by coverage instead of staying sharp |
| [09-baseline-vs-now](./09-baseline-vs-now/README.md) | Summary: QGIS · start · now, with the difference numbers |
| [10-furniture-shadows-and-outlines](./10-furniture-shadows-and-outlines/README.md) | Patch: `fill-shadow-*`; parking spaces, 1 px outlines and inner-shadow filter fixed |
| [11-marker-rows](./11-marker-rows/README.md) | Bollard rows, embankment ticks and separation markers that rendered nothing |
| [12-ground-sized-rotated-textures](./12-ground-sized-rotated-textures/README.md) | Patch: `fill-pattern-reference-zoom` and `fill-pattern-rotate` for surface textures |
| [13-trees-and-street-icons](./13-trees-and-street-icons/README.md) | Tree crown resampling and shadow; hydrant, bicycle, box and street-lamp icons as in QGIS |
| [14-new-qgis-style](./14-new-qgis-style/README.md) | New QGIS style: parked cars, tree variants from z15, kerb shade, one-way arrows, construction and traffic calming |

## Adding a step

```bash
cd vector
bun run dev                                          # in another terminal
SHOT_OUT=compare-output/<name> bun run screenshots   # QGIS + vector PNGs per location (git-ignored)
bun run scripts/montage.ts ../docs/maplibre-progress/NN-<name> \
  qgis=<name>/raster before=<previous>/vector after=<name>/vector
```

Keep the previous run in `compare-output/` so the next step has its "before". Add a README to
the new folder and a row to the table above.
