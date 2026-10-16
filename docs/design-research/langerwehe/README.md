# Langerwehe: three styles in a small town

Test run of the three Straßenraumkarte styles on a small town (Langerwehe, NRW), to compare with the Berlin-Neukölln material used so far.

- **QGIS heute**: today's QGIS style (`style/strassenraumkarte.qgz`)
- **la**: Rust renderer, `--layers la` (landscape-architecture site plan)
- **ink**: Rust renderer, `--layers ink` (fantasy-book ink map)
- **ink-oblique**: `--layers ink` with `SRK_INK_OBLIQUE=freestanding` (freestanding buildings)

## Setup

| | |
| --- | --- |
| Bbox (WGS84) | `6.335,50.805,6.381,50.827` (village node Langerwehe at 6.3581, 50.8176, inside) |
| Source | `germany-latest.osm.pbf`, extracted with `osmium extract` (53 s, 406 KB) |
| Database | `strassenraumkarte_langerwehe` (separate DB, same container; the shared `strassenraumkarte` DB was not touched) |
| Import | `run.sh --setup-db --skip-render` in the tools container: about 48 s including DB setup |
| Zoom range | z15–19, 4 803 tiles per style (25 / 72 / 252 / 918 / 3 536) |

Timings (from `timing.json` for the Rust styles, wall clock for QGIS):

| Style | Tiles | Wall time | Per tile | Setup |
| --- | --- | --- | --- | --- |
| QGIS heute | 4 803 | 11 min 15 s | about 140 ms | `render_tiles.sh`, 3 workers, metatile 4, gutter 1, jpg |
| la | 4 803 | 227 s | 47 ms | 4 workers, metatile 4, gutter 1, webp |
| ink | 4 803 | 217 s | 45 ms | as la |
| ink-oblique | 4 803 | 140 s | 29 ms | as la, `SRK_INK_OBLIQUE=freestanding` |

Viewer: `http://127.0.0.1:8018/` (local only; a plain `python3 -m http.server` over `tmp/langerwehe/www`, which holds symlinks to the four tile folders). Default view is z17 at the village centre, with QGIS on the left and la on the right; `#mode=swipe&a=qgis&b=ink` switches the pair.

## Comparison crops

Each crop is a 2×2 block of tiles, one panel per style, in the order QGIS / la / ink / ink-oblique. Made by `make_crops.py`.

1. **Centre, z18** (`img/centre_z18.jpg`): Bahnhofstraße and the rail line. Left to right: QGIS, la, ink, ink-oblique.
2. **Park and Ride and Haltepunkt, z18** (`img/haltepunkt_z18.jpg`): the rail crossing, a watercourse and the stop area.
3. **Schützenstraße / Apollonstraße area, residential, z19** (`img/residential_z19.jpg`): detached houses on curved residential streets.

Image sizes: 190–205 KB each.

## What works

- **Scale carries over.** The small-town extent renders at the same tile resolution and symbol size as Berlin, so the three styles can be compared directly at identical zooms.
- **Ink and la read well at village scale.** Serif street names along curved roads, hatched building roofs and the hedge/tree textures keep the rural streets legible.
- **Water.** The watercourse is the strongest element at the Haltepunkt crop in all styles. In the crop, ink's outline treatment reads more clearly than QGIS's flat blue.
- **Freestanding buildings (ink-oblique).** Compared with plain ink, the oblique variant adds only a small depth offset to the buildings at z18–19; the difference is visible but subtle.

## What breaks or looks odd

These are observations from the three crops and the import log, not measured results.

- **Residential labels.** In the z19 residential crop, QGIS shows no street names, while la and ink label the streets. At z18 QGIS labels are faint. Not checked whether this is a label-density rule or missing data.
- **Rail and station.** The extract has no station node or building in the bbox (no `railway=station` found). The "Bahnhof" area is a Park and Ride with buffer stops (4 `buffer_stop` nodes near 6.3510, 50.8173). Station-specific symbols therefore cannot be checked here.
- **Trees.** The `tree` table holds about 147 000 points for this extract. Ink draws them as outlines; the crops show tree texture next to the village. The number is larger than the visible street trees suggest; source of the points (forest/hedge generation vs. tagged trees) not yet checked.
- **Road data.** The extract has 1 329 highway segments, 736 `lanes` rows and 3 486 buildings. Many lanes and sidewalks in the countryside are tagged less consistently than in Berlin, so road cross-sections in la and ink can look thinner or more uniform than the streets actually are. Not verified against the source tags.
- **Rural landuse.** Fields and meadows dominate the edge of the crops and carry little detail, so the base colour does most of the work. Not checked how well fields and gardens separate in each style.
- **Freestanding buildings.** ink-oblique differs from ink only subtly at z18–19 (see above), so the variant is hard to tell apart in this extract.

## Reproduce

```bash
# extract (run from repo root)
osmium extract -b 6.335,50.805,6.381,50.827 ~/Development/_osm-pbfs/germany-latest.osm.pbf \
  -o tmp/langerwehe/langerwehe.osm.pbf --overwrite

# import into a separate DB (tools container; docker/.env needs BERLIN_PBF_MOUNT set to the extract)
docker compose -f docker/docker-compose.yml --env-file docker/.env run --rm \
  -e DB_NAME=strassenraumkarte_langerwehe tools \
  ./run.sh --setup-db --data data/osm/berlin-latest.osm.pbf --bbox 6.335,50.805,6.381,50.827 --skip-render

# Rust presets (DB_PORT=5433, DB_NAME=strassenraumkarte_langerwehe, PGPASSWORD set in the shell)
cd rust/srk-render && cargo build --release && cd ../..
./rust/srk-render/target/release/srk-render --bbox 6.335,50.805,6.381,50.827 --zmin 15 --zmax 19 \
  --layers la --metatile 4 --gutter 1 --workers 4 --format webp --out tmp/langerwehe/la

# QGIS: temp project with the datasource DB name switched (committed project untouched)
# then render_tiles.sh --project tmp/langerwehe/strassenraumkarte_langerwehe.qgz ...

# crops
python3 docs/design-research/langerwehe/make_crops.py
```

Tiles and the temp QGIS project live in `tmp/langerwehe/` (gitignored).
