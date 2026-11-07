# QGIS `highway_area` paint rules (authoritative dump)

Source: `style/strassenraumkarte.qgz` → `strassenraumkarte.qgs` XML (parsed 2026-08-01).  
PyQGIS full-project load was too slow for this pass; XML agrees with `docs/maplibre-style-groups.md` G4.

## Layer tree (checked)

Seven maplayers named `highway_area`, all `Qt::Checked`:

| Datasource SQL filter | Role |
| --- | --- |
| `"layer" >= 3` | OSM layer bucket |
| `"layer" = 2` | OSM layer bucket |
| `"layer" = 1` | OSM layer bucket |
| `"layer" = 0 OR "layer" IS NULL` | OSM layer bucket |
| `"layer" = -1` | OSM layer bucket |
| `"layer" <= -2` | OSM layer bucket |
| *(none)* | Unlayered duplicate (same rules) |

No layer-level scale visibility for these entries. Isolating `--layers highway_area` paints every checked maplayer with that name (bucket overlap → same fill over-painted, visually identical).

## Rule-based renderer (13 rules, identical on all 7)

### Class fills (SimpleFill) — painted `area:highway` values

| Rule | Filter | Fill | Outline |
| --- | --- | --- | --- |
| footway | `IN ('footway','path','steps','bridleway')` | `#e1e3bd` | same colour, **width 0** |
| pedestrian | `= 'pedestrian'` | `#d7d8c5` | same, width 0 |
| cycleway | `= 'cycleway'` | `#cccccc` | same, width 0 |
| service | `= 'service'` | `#cccccc` | same, width 0 |
| parking | `= 'parking'` | `#a8a8a7` | same, width 0 |
| living_street | `= 'living_street'` | `#bbbbb2` | same, width 0 |
| road | `IN ('primary','primary_link','secondary','secondary_link','tertiary','tertiary_link','residential','unclassified','road','bus_guideway','bus_bay','turning_circle','turning_loop')` | `#a8a8a7` | same, width 0 |
| motorway | `IN ('motorway','trunk','motorway_link','trunk_link')` | `#a8a8a7` | same, width 0 |

**Not painted** (no ELSE rule): e.g. `parking_space`, `traffic_island`, and any other `area:highway` outside the lists above. That is the main smoke-suite gap vs a catch-all Rust palette.

Data-defined fill tweaks (present in symbols, but **no matching columns** on `public.highway_area`):

- footway: `if("footway"='sidewalk' or "path"='sidewalk', '#ebedd6', '#e1e3bd')`
- service: `if("service"='crossover', '#dcddd1', '#cccccc')`

These cannot fire against the current PostGIS schema; flat base colours apply.

### Surface overlays (RasterFill) — skipped in Rust slice

`concrete:plates`, `concrete`, `paving_stones`, `sett`, `asphalt` — texture overlays with effect stacks. Expected remaining gap (no textures / no innerShadow blur).

## Scale / zoom

Class-fill rules have **no** `scalemindenom` / `scalemaxdenom`. Features matching the filters are visible at z15–18 (and beyond) for this isolate. The separate z14–z20 carriageway blur stack is **not** named `highway_area` in the project (not part of this isolate).

## Implications for `srk-render`

1. SQL `WHERE "area:highway" IN (…union of class filters…)` — do **not** paint unknown classes.
2. Palette = table above; no dark stroke (`outline_width=0` in QGIS).
3. Still expect AA / missing RasterFill + effect soft-edge residual vs QGIS.
