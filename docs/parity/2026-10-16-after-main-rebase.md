# Parity after rebasing onto main (05991fe), 2026-10-16

PR #7 (`experiment-rust-pixel-port-vector-map`) was rebased onto `main` 05991fe: Supaplex030's
new processing pipeline, render tooling and QGIS style (`style/strassenraumkarte.qgz`, new car
and tree symbols). This note records how the conflicts were resolved, what broke, and a fresh
QGIS-vs-Rust and QGIS-vs-MapLibre baseline against the **new** style.

## Rebase resolutions

The six-commit structure is unchanged; every fix sits in the commit it belongs to. Main is the
authority for the QGIS pipeline and render tooling.

| File | Resolution |
| --- | --- |
| `render/xyz_tiles.py` | Main's renderer as is, plus a 3-line import of the new `render/qt_compat.py`. Main's code uses Qt5 enum names (`QImage.Format_ARGB32_Premultiplied`, `QgsMapSettings.Antialiasing`, …) that PyQt6 / QGIS 4 (macOS QGIS.app) no longer exposes. `qt_compat.install()` aliases the scoped members and is a no-op on QGIS 3. The PR's own renderer (`--tiles`, `--layers`, `--workers`, font registration, audit summary) is dropped. |
| `render/render_tiles.sh` | Main's script, plus PR changes still needed on macOS: source `render/qgis_env.sh`, run `$PYTHON` (QGIS.app python) instead of `python3`, and use `tr` in place of bash-4 `${var,,}`, because macOS `/bin/bash` is 3.2. The PR's `--tiles` / `--layers` / `--workers` / `--fonts-dir` flags are dropped (see harness below). |
| `render/tiles/preview.html` | Main's version. The PR's Catalyst restyle (CSS only) is dropped because main rewrote the page. |
| `data/data_preparation.sh` | Main's step list, plus the PR's additions: `audit/lib.sh` perf timing (`perf_step` / labelled `run_sql`), the cached osmium extracts under `tmp/osm-extracts/`, the `OSM2PGSQL_NUMBER_PROCESSES` switch, and the `roof_shape.sql` stage (`ROOF_SHAPES`) right after `building.sql`. Main's `log_tee.sh` and the PR's `audit/lib.sh` are both sourced. |
| `data/processing/sql/building.sql` | Main's rewrite (face/point dissolve, `ST_ClusterDBSCAN`, `ST_CoverageUnion`). The PR's faster `&&`/`NOT ST_Touches` overlap join was dropped because main replaced that query. The PR's determinism fixes in steps B/C (`DISTINCT ON` largest outline, tie-break on `outline_id`) still apply to main's unchanged code and are kept. |
| `data/lua/osm_import.lua` | Auto-merged: `roof:colour` and `building:colour` are still imported on top of main's changes. |
| `data/example bash commands` | Deleted (main removed it). |
| `run.sh` | Main's `--render-only` flow, plus the PR's `qgis_env.sh` / `$PYTHON` / PyQGIS check, `--skip-render` without QGIS, and perf audit init (now inside main's non-render-only branch). |
| `.gitignore` | Main's `data/parking/**` and `logs/*` lines, plus all PR lines. |
| `docker/Dockerfile` | Added `gdal-bin`: main's `data_preparation.sh` runs `ogr2ogr` for the street parking import, which the tools image could not do. **This fix also belongs upstream on main.** |
| `audit/tile-regression/scripts/qgis_tiles.py` (new) | A harness wrapper around main's `xyz_tiles.py`. It reuses `init_render_context` + `render_metatile` and adds `--tiles`, `--layers`, `--skip-layers` (ablation) and registration of the bundled `render/fonts` (Open Sans, hooked in before the project loads). `render-qgis-tile.sh` calls it, so `render-suite*.sh` and `bench-bbox.sh` work unchanged. The harness was adapted instead of main's renderer. |
| harness `render_tiles.sh` callers | `--workers N` changed to `--jobs N` (`bench-bbox.sh`, `freeze-reference.sh`, `audit/render-explore/*.sh`). The render-explore scripts note that main's renderer writes no per-metatile audit summary. |
| `vector/vite.config.ts` | `/raster/*` also serves `.webp` (main's `render_tiles.sh` default), and `QGIS_TILES_ROOT` points the compare at any QGIS tile folder. |

## Import (new pipeline)

`BBOX=13.4102,52.4680,13.4520,52.4832 ./docker/run-berlin.sh` re-imported the dev DB
`strassenraumkarte` (Docker `strassenraumkarte-db-1`, :5433). TILDA street parking came from
`data/parking/street_parking.gpkg`, which is gitignored and not committed.

| Step | Time |
| --- | ---: |
| osm2pgsql (cached 1.8 MB extract, 126k nodes / 13k ways) | 1 s |
| `building.sql` + `roof_shape.sql` | 184 s |
| street parking: `ogr2ogr` + `street_parking.sql` + `street_parking_point.sql` | 10 s |
| all other SQL incl. `render_prepare.sql` | ~11 s |
| **Total wall time (`run-berlin.sh`)** | **208 s** |

`roof_shape.sql` still runs after main's `building.sql`: it reads `building."roof:shape"` and
writes its own `roof_mass`, `roof_facet` and `roof_shape_line`, and main's `building.sql` still
reads and drops `roof_line`. The import produced 1 549 roof masses, 15 264 facets, 29 548 ridge
or edge lines, 6 014 buildings, 11 527 trees, 1 936 street parking lines, 13 453 vehicle points,
95 `highway_oneway` and 21 `tunnel_entrance` rows.

## Schema fixes in the renderers

| Breakage | Fix |
| --- | --- |
| `tree.rotation` dropped. QGIS now draws angle `rand(-20, 20, "osm_id")`. | Rust (`layers.rs` `paint_tree`) and the vector export (`vector/layers.ts`) derive `((osm_id % 41 + 41) % 41 - 20)` when the column is missing. |
| `style/symbols/trees/{broadleaved,needleleaved}.png` became `broadleaved01–19`, `needleleaved01–06`, `shrub01–06`. Rust fell back to procedural crowns, and `bun run sprite` crashed. | Rust `tree_markers.rs` loads every variant (`load_variants`) and picks one per tree from a stable coordinate hash. QGIS uses `rand(1, N, "tid")`, which is not reproduced. The vector sprite packs `*01` only. |
| New `landuse` rows clip to `POLYGON EMPTY`, and the wkb reader rejected them (`warn: skip landuse WKB … UnexpectedEof`). | `paint.rs` `decode_wkb` returns an empty collection for zero-count WKB. |

With these fixes, `cargo build --release` and `cargo test --release` pass (25 passed; the 4
`#[ignore]`d tests are known limitations). All 10 manifest tiles render with `--layers
full-approx`, `la` and `ink` with no stderr warnings. Running `vector/` `bun run pipeline`,
`bun run sprite` and `bun run check` gives 1 197 style layers, valid, with 15 tests passing.
`render/render_tiles.sh` (main's renderer) also renders on macOS QGIS 4.2.1.

## QGIS vs Rust full-approx (10 manifest tiles)

These numbers come from `./audit/tile-regression/scripts/render-suite-full.sh --run-dir
/tmp/parity2/run1`, with QGIS 4.2.1, main's style, PNG output, metatile 1, gutter 1 and
pixelmatch threshold 0.1. The QGIS reference stays in `/tmp/parity2/run1/qgis` for later agents.

**Before** is the old base: old style, old DB, from `audit/tile-regression/parity-2026-10-16/`.
**No cars** uses the same QGIS reference rendered with `--skip-layers "street parking (<= z17),street parking (> z17)"`.

| Tile | Before | Now | Now, QGIS without cars |
| --- | ---: | ---: | ---: |
| 15/17605/10752 | 11.0 % | 6.12 % | 6.12 % |
| 15/17606/10752 | 7.1 % | 5.72 % | 5.72 % |
| 16/35211/21505 | 6.2 % | 5.54 % | 4.43 % |
| 16/35212/21505 | 6.0 % | 5.29 % | 4.70 % |
| 17/70422/43011 (Herrfurthplatz) | 1.5 % | 3.44 % | 2.04 % |
| 17/70425/43010 | 2.0 % | 5.48 % | 4.27 % |
| 18/140845/86023 | 1.1 % | 4.23 % | 2.15 % |
| 18/140851/86021 | 1.0 % | 3.98 % | 2.86 % |
| 19/281691/172046 | 0.9 % | 4.84 % | 2.09 % |
| 20/563382/344092 | 1.2 % | 2.98 % | 2.98 % |
| **Mean** | **3.82 %** | **4.76 %** | **3.74 %** |

Parked cars account for about 1 percentage point of the mean, and for up to 2.8 points at
z18/z19. The rest of the z17+ loss comes from the new kerb shading, the tree crown variants and
the new layers listed below. The z15/16 rows cannot be compared with the old run, because both the
import bbox and the style changed. Their remaining difference is mostly the forest tree crowns
that QGIS now draws at every zoom.

## QGIS vs MapLibre (8 compare locations)

These numbers come from `bun run screenshots` (`vector/scripts/screenshots.ts`, 1280×800, two
panes, pixelmatch 0.1) against QGIS tiles of the new style. The 270 tiles came from
`render-qgis-tile.sh` into `/tmp/parity2/qgis-compare` (z = location zoom + 1, capped at 20,
the tiles MapLibre requests for a 256 px raster source). They were served with
`QGIS_TILES_ROOT=/tmp/parity2/qgis-compare bun run dev`. **Before** is the last committed step,
[`maplibre-progress/13`](../maplibre-progress/13-trees-and-street-icons/README.md), against
the old style.

| Location | Before | Now |
| --- | ---: | ---: |
| Intersection, z18 | 3.02 % | 5.79 % |
| Dense trees, z18 | 1.88 % | 4.31 % |
| Dense housing, z17 | 5.22 % | 5.79 % |
| Residential street, z19 | 2.43 % | 3.10 % |
| Playground, z18 | 3.35 % | 3.40 % |
| Courtyard furniture, z19 | 3.42 % | 7.89 % |
| Sett street, z20 | 2.38 % | 8.91 % |
| Park / water, z17 | 3.40 % | 3.99 % |
| **Mean** | **3.14 %** | **5.40 %** |

"Dense trees" (52.484 N) lies partly north of the import bbox (52.4832 N). Both panes are empty
there, so the score is still comparable. Most of the increase is parked cars, which are most
visible at the sett street and the courtyard.

## Gaps: what QGIS draws now that we do not (prioritised)

### Rust (`rust/srk-render`)

1. **Parked cars (`street_parking_point`)**, worth about 1 pt of the mean and 2–3 pt at z17–19.
   - **QGIS:** layers `street parking (<= z17)` and `(> z17)`, split at 1:2000 and repeated per OSM `layer` bucket. Each is an SvgMarker `symbols/cars/<type>.svg` (`motor_vehicle01/02`, `bus`, `hgv`, `hgv_articulated`, `taxi`, `emergency`) with fill = `colour`, angle = `angle` and width `2.4 * @mercator_scale`, plus a drop-shadow effect stack at layer opacity 0.67.
   - **Change:** add `paint_street_parking_point` in `layers.rs`, with a `table_exists` flag in the layer cache (`layers.rs` ~l. 1975). Query `type, colour, angle, layer, geom`. Stamp through `svg_stamps.rs` (`SvgStampCatalog`, which needs a per-feature fill override), add the call to the full-approx draw order (`main.rs` / `layers.rs` preset list) at the same position as in the QGIS layer tree, and reuse the furniture drop shadow from `paint.rs`.
2. **Tree crowns below z17.** QGIS `tree crown (<= z17)` draws all trees, including the forest-generated ones, at every zoom, which gives the dense canopy texture at z15/16. `layers.rs` `paint_tree` returns early for `z < 17`; lower or remove that gate and check the `<= z17` symbol variant.
3. **Kerb shading moved.** QGIS dropped the `highway_area` `z14`–`z20` inner-shadow layers. It now draws `barrier_way` `kerb shade` (Lineburst plus effect stack, `kerb != 'flush'`) and a `kerb` line. Replace `layers.rs` `paint_highway_kerb_shade` (and the class list near l. 425) with a Lineburst-like band along `barrier_way` kerbs (`paint.rs` inner-shadow helpers). The kerb stroke is in `furniture_batch_b.rs`.
4. **`highway_oneway` arrows** (new table): line plus MarkerLine arrows. There is no Rust layer yet; add one next to `paint_road_marking_way`.
5. **`tunnel_entrance` outline + shade** (new table, GradientFill). Not drawn yet.
6. **Tree crown image choice.** QGIS uses `rand(1, 19|6, "tid")`, and Rust uses a coordinate hash (`tree_markers.rs` `sprite_for`), so individual crowns differ. Matching it needs QGIS's seeded `rand` and the `tid` column, which `render_prepare.sql` adds.
7. **New import classes and style splits.**
   - `landuse` `commercial` / `industrial` / `schoolyard`: for example, the hatched block west of Karstadt in `17/70425/43010` is missing; check `paint_landuse` / `paint_texture_rule`.
   - `scrub` is now split into `> z16` / `<= z16`.
   - New `cycle barrier` layer (`furniture_batch_b.rs` `cycle_barrier`).
   - `traffic_calming` and `gantry` features.

### MapLibre (`vector/`)

1. **Parked cars.**
   - **Export:** add a `street_parking_point` export layer in `vector/layers.ts` with `type, colour, angle, layer`, group `detail`, from z15 because QGIS draws it at every zoom.
   - **Sprite:** pack `style/symbols/cars/*.svg` in `src/style/sprite-icons.ts`. The fill is a per-feature hex (`colour`), so either use SDF icons with `icon-color` (silhouette) plus an untinted detail overlay, or quantise `colour` into a few baked variants.
   - **Layer:** `icon-rotate: angle`, `icon-rotation-alignment: map` and size from `metresToPixels(2.4)`. Then add `symbol-layer-opacity` 0.67 and a baked shadow like the tree crowns (`detail.ts`).
2. **Tree crowns.** Only `broadleaved01` / `needleleaved01` are packed. Shrubs should use `shrub01–06`, and crowns should also show at z15–16 (the `tree` layer starts at z17 in `layers.ts`; `detail.ts` tree layers).
3. **Kerb shading.** Replace the `highway_area` blur bands (`streets.ts` `CARRIAGEWAY_BLUR_FILTER`) with a blurred inner line on `barrier_way` kerbs (`furniture.ts` kerb, `effects.ts`).
4. **`highway_oneway`** (line + arrow `symbol-placement: line`) and **`tunnel_entrance`** (fill + gradient approximated by blurred bands) are new export layers.
5. **New landuse classes and scrub split** (`ground.ts` / `landscape.ts`), new `cycle barrier`, `traffic_calming`, `gantry`.

## Not fixed / follow-ups

- Main's `render/xyz_tiles.py` fails on QGIS 4 / PyQt6 without `qt_compat.py`. That fix, the bash-3.2 `${var,,}` replacements in `render_tiles.sh`, and `gdal-bin` in `docker/Dockerfile` also belong on main.
- Main's renderer does not register `render/fonts`. Production renders need Open Sans installed on the system; the harness registers it itself.
- `audit/render-explore/*` reports were measured with the PR's former renderer. Re-running them now gives only wall time and tile counts.

## Update: after the fix passes (2026-10-16, afternoon)

Three passes on top of the rebase, measured against the same QGIS reference (main's style, with TILDA street parking), 10 manifest tiles, `--metatile 1 --gutter 1`:

- **Parked cars + trees** — `paint_street_parking_point` (car SVGs with per-feature fill, `angle`, 2.4 m × @mercator_scale, opacity 0.67, shadow below 1:2000); trees at every zoom, below z17 under landuse/paving/roads/buildings as in the project's layer order. Tree image choice is a coordinate hash (QGIS `rand(1,N,tid)` not reproduced).
- **Kerbs + new layers** (`street_detail.rs`) — kerb Lineburst shade along `barrier_way` kerbs replaces the carriageway inner shadow; kerb line widths; no fill for landuse classes without a QGIS category; construction hatch; tunnel entrances; traffic-calming markers. Oneway arrows implemented but off: the QGIS rules test `turn:lanes`, which `highway_oneway` does not have, so QGIS draws none either.
- **Design styles** — parked cars as variant `SRK_CARS=on` in `la` (plan blocks) and `ink` (carts, horses, rare dragons); off by default.

| Tile | After rebase | Now |
|---|--:|--:|
| 15/17605/10752 | 6.12 | 4.37 |
| 15/17606/10752 | 5.72 | 4.94 |
| 16/35211/21505 | 5.54 | 2.23 |
| 16/35212/21505 | 5.29 | 2.98 |
| 17/70422/43011 | 3.44 | 1.74 |
| 17/70425/43010 | 5.48 | 2.45 |
| 18/140845/86023 | 4.23 | 1.40 |
| 18/140851/86021 | 3.98 | 0.96 |
| 19/281691/172046 | 4.84 | 1.26 |
| 20/563382/344092 | 2.98 | 1.85 |
| **Mean (%)** | **4.76** | **2.42** |

Remaining Rust gaps: carriageway texture strength at z17–18, QGIS custom layer order in general, tree image choice, cycle barrier variants, gantries (no data). Finding: QGIS scale thresholds behave like ground scale (map units per px ÷ Web Mercator factor), not 1:n at 96 DPI — relevant for every scale-gated layer.
