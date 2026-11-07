# Rust raster map rendering

Research notes on reimplementing the Straßenraumkarte **rendering step** in Rust: PostGIS geometries + style definition in, identical-looking raster XYZ tiles out. Covers CPU/GPU rasterizers, SVG symbols, blur/effects, text/labels, PostGIS I/O, tile encoding, WASM viability, and determinism.

## Contents

| File | Purpose |
| --- | --- |
| [summary.md](./summary.md) | Decision-oriented chapters: rasterizer choice, effects, labels, stack recommendation |
| [sources.md](./sources.md) | Bibliography: URLs researched and short summaries |

## Scope

Focus is **pixel generation and tile plumbing** for a QGIS-style raster tile pipeline — not geometry computation (see `.agents/skills/rust-wasm-geo/`) and not MapLibre Style Spec authoring (see `research/maplibre-special-case-styling/`). Evaluates native server-side rendering first; WASM/browser painting is a secondary track.
