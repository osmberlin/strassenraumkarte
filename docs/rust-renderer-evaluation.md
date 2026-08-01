# Rust renderer evaluation (stub)

**Status:** interim — Phase 4 go/no-go not complete.

Current evidence for the `highway_area` vertical slice (isolate, metatile 1, PNG smoke suite) lives in:

- [`audit/tile-regression/REPORT.md`](../audit/tile-regression/REPORT.md) — before/after metrics, method, remaining gaps
- [`audit/tile-regression/HIGHWAY_AREA_RULES.md`](../audit/tile-regression/HIGHWAY_AREA_RULES.md) — QGIS rule dump
- [`audit/tile-regression/RENDER_MODE.md`](../audit/tile-regression/RENDER_MODE.md) — canonical compare mode
- Latest gallery: [`audit/tile-regression/runs/20260801-172219-smoke/index.html`](../audit/tile-regression/runs/20260801-172219-smoke/index.html)

Headline (2026-08-01 smoke, 12 tiles z15–18): mean pixelmatch **0.079%**, max **0.203%**, all tiles in `ok` after aligning Rust filters with QGIS class-fill rules.

This document will expand to the full go / hybrid / stop recommendation once more layer groups, effects, and timing benchmarks are measured.
