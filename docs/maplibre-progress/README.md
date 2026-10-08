# MapLibre port — visual progress

One folder per step, each with side-by-side screenshots at the compare locations
(`vector/locations.ts`) and a short README saying what changed and what to look at.
The QGIS raster tiles are the reference.

| Step | What |
|---|---|
| [00-baseline](./00-baseline/README.md) | State of the port before renderer patches |
| [01-layer-blend-multiply](./01-layer-blend-multiply/README.md) | First MapLibre patch: `fill-layer-blend: multiply` for surface textures |

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
