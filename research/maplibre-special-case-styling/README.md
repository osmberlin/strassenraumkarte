# MapLibre special-case styling

Research notes on how to recreate hard cartographic effects (soft landcover, dual-resolution data, palette remaps, layer sandwiches, etc.) when styling with **MapLibre** / the MapLibre Style Spec — especially techniques documented while Stamen rebuilt Terrain and Toner as vector styles for Stadia Maps.

## Contents

| File | Purpose |
| --- | --- |
| [summary.md](./summary.md) | Problem → solution chapters for special styling cases |
| [sources.md](./sources.md) | Bibliography: URLs researched and short summaries |

## Scope

Focus is **workarounds and patterns** for cases where MapLibre cannot do what raster cartography (Mapnik/Photoshop-style blur, patterned fills, fixed label offsets) did natively — not a full MapLibre tutorial.
