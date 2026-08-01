# Tile visual regression testing

Research notes on **methodology and tooling** for proving that a new tile renderer (planned Rust reimplementation) matches the existing PyQGIS reference engine — at single-tile, per-layer, and map-wide sampling scales.

## Contents

| File | Purpose |
| --- | --- |
| [summary.md](./summary.md) | Decision-oriented chapters: metrics, prior art, sampling, seams, triage, CI, recommended harness |
| [sources.md](./sources.md) | Bibliography: URLs researched and short summaries |

## Scope

Focus is **how to compare rendered map tiles rigorously** (metrics, fixtures, thresholds, reports, incremental migration), not how to implement the Rust renderer itself.

This repo already has related tooling:

- `audit/tile-compare/` — SSIM + capped pixel-diff for **two QGIS tile trees** (e.g. worker-count A/B).
- `vector/scripts/screenshots.ts` — Playwright + `pixelmatch` HTML gallery for raster vs MapLibre vector.
- `audit/sql-compare/` — frozen PostGIS digests for data-prep equivalence.

The harness design in [summary.md §7](./summary.md#7-recommended-harness-design-for-this-repo) extends these patterns for **reference (QGIS) vs candidate (Rust)** migration tracking.
