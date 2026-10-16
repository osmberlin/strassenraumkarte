# Roof shapes for the design-research styles

Branch `claude/design-roof-shapes-5961f4`. Scope: research, a data probe, and a working prototype of roof geometry (ridges, hips, gables, facets) built in SQL from OSM footprints and rendered by a preview preset. The `ink` and `la` styles are **not** edited here (other sessions own `style_ink.rs`, `style_la.rs`, `style_kit.rs`); section 8 says how each should use the new tables after merging.

## 1. Summary

- **Built:** `data/processing/sql/roof_shape.sql` creates three tables from building outlines: `roof_mass` (one roof per group of touching buildings), `roof_facet` (planes with compass aspect) and `roof_shape_line` (ridge, hip, parapet). Hooked into `data_preparation.sh` right after `building.sql`.
- **Method:** touching outlines of the same roof kind are merged into one mass, the mass is closed and simplified, and hipped roofs come from the **straight skeleton** (SFCGAL `CG_StraightSkeleton`). Gabled roofs are a **centreline split** of the oriented envelope. Flat roofs get a parapet line.
- **Works:** courtyard blocks (holes) and Gründerzeit rows read as roofs in plan: hips at corners, ridges along the wings, slopes into the courtyard. Tagged pyramids and gables read correctly. No skeleton failures on the Schillerkiez bbox.
- **Does not (yet):** tiny bowtie facets where courtyard wings are narrow; L-shaped gables are only approximated; skillions are treated as flat because `roof:direction` is not imported; valleys are not classified separately (they come out as `hip`).
- **Runtime:** about 65 s for the whole bbox on first run; later runs took 4–6 min on the shared dev DB while other sessions were busy (measured, not optimised).

## 2. Data coverage (dev DB, Schillerkiez–Körnerpark bbox, 2026-10-16)

`building` holds 6,014 rows: **3,505 outlines** (`building` set) and **2,509 `building:part`** volumes. Parts have no `building` value, so `building IS NOT NULL` selects outlines.

| Item | Count | Share |
| --- | --- | --- |
| Outlines, excluding `building=roof` canopies (120) | 3,385 | |
| …with `roof:shape` | 577 | 17.0 % |
| …with `building:levels` | 3,149 | 93 % |
| Parts with `roof:shape` | 348 of 2,509 | 13.9 % |
| `building=roof` (canopies, skipped) | 120 | |

`roof:shape` on outlines: none 2,808 · flat 220 · gabled 132 · **double_saltbox 130** · skillion 28 · hipped 22 · saltbox 20 · pyramidal 12 · quadruple_saltbox 4 · gambrel 3 · many 2 · round 2 · cone 1 · `hipped;flat` 1.

- **Not imported:** `roof:direction`, `roof:orientation`, `roof:angle`, `roof:height`, `roof:levels`. `data/lua/osm_import.lua` imports only `roof:shape` for `building`; `roof_line` carries `roof:ridge` / `roof:edge` as lines. Adding `roof:direction` and `roof:orientation` to the Lua attribute list would make skillions and some gables exact. That needs a re-import, which this branch does not do.
- **Attached:** 3,414 pairs of outlines touch. Of 2,808 untagged outlines, about 2,550 (≈ 90 %) touch or overlap another outline. This is the Berlin situation: rows and perimeter blocks, not free-standing houses.
- **Storeys:** the untagged attached outlines are mostly 5 storeys (1,409), with 3–4 (265) and 6 (79). The Schillerkiez default is therefore 3–6 storeys = Gründerzeit.

## 3. Why per-building skeletons look wrong, and how to connect them

A straight skeleton of one house in a row gives hip ends on both party walls. Each house gets its own ridge stub, and the ridge stops at every party wall. In a real Berlin row the roof is one continuous mass: the ridge runs along the whole street front, and the party walls are invisible.

The connection step in `roof_shape.sql`:

1. Group outlines by resolved roof kind (section 5). Touching outlines of the same kind form one cluster (`ST_ClusterDBSCAN(geom, 0.01, 1)` as a window function).
2. `ST_Union` each cluster. Interior party walls disappear; courtyards stay as holes.
3. Close with a 1.2 m buffer (mitre joins) to absorb wall jogs and bay-window notches, then simplify to 0.4 m.
4. **Caps:** a cluster above 9,000 m² or 60 buildings falls back to one mass per building. On the bbox no hipped or gabled mass hit the cap; the largest hipped mass is 8,996 m².

Result on the bbox: 1,527 masses from 3,385 outlines (531 hipped masses with 1,815 buildings, 244 gabled with 382, 774 flat with 1,139; 123 masses have courtyards).

## 4. Geometry methods compared

| Method | Use | Verdict |
| --- | --- | --- |
| **Straight skeleton** (`CG_StraightSkeleton`, SFCGAL 1.4.1 in `postgis_sfcgal` 3.5.3, already installed in the dev DB) | Hipped roofs, polygons with holes | **Chosen.** Exact for rectangles and courtyard rings; supports holes (input must be CCW exterior, `ST_ForcePolygonCCW`). Facets are obtained by polygonizing boundary plus skeleton. Sensitive to jagged boundaries, hence the closing and simplification. Slowest step. |
| Approximate medial axis (`ST_ApproximateMedialAxis`, GEOS) | Ridge lines only | Not used. It yields spurs at every corner and no facet polygons, so it cannot shade planes. |
| Oriented envelope + centreline split | Gabled roofs | **Chosen for gables.** Two planes split by the centreline of the envelope's long axis; exact for rectangles, full-length ridge with gable ends; approximate for L shapes. Cheap and never fails. |
| Own decomposition into rectangles, then per-piece gable/hip | L shapes, wings | Not built. The next step if the centreline fallback looks wrong on L-shaped blocks. |

Precedents (from memory, not re-checked in this session): the OSM wiki's *Simple 3D Buildings* scheme defines the `roof:shape` / `roof:direction` / `roof:orientation` / `roof:height` tags used here. OSM-3D / OSMBuildings and F4Map build roofs from footprints with `roof:shape`; osm2world generates gable and hip roofs with skeleton-type constructions. Confirm before citing.

## 5. Sanitising rules

| Input | Rule |
| --- | --- |
| Outlines only (`building IS NOT NULL`) | Parts overlap their outline; using both would double every roof. |
| `building=roof` | Skipped (canopies have no walls). |
| Area < 8 m² | Dropped (slivers). |
| `roof:shape` flat, skillion | → **flat**. A skillion needs `roof:direction`, which is not imported. |
| gabled, saltbox, double_saltbox, quadruple_saltbox, gambrel | → **gabled** (centreline split). |
| hipped, pyramidal, mansard, round, onion, cone, dome | → **hipped** (straight skeleton; a square footprint gives a pyramid). |
| Unknown, multi-valued (`hipped;flat`, `many`) | → default rule. |
| Default, sheds/garages, `building` in garage(s), shed, carport, service, greenhouse, storage_tank, hut, kiosk | flat |
| Default, area < 25 m² | flat |
| Default, attached, 3–6 storeys | **hipped** (Gründerzeit row or block) |
| Default, attached, 1–2 or 7+ storeys | flat (extensions, modern blocks) |
| Default, detached, area ≥ 350 m² or ≥ 5 storeys | flat |
| Default, detached, elongated (long/short ≥ 1.25) | gabled |
| Default, otherwise | hipped |
| Flat masses ≥ 150 m² | parapet line 0.5 m inside the edge |

## 6. Output tables

- `roof_mass(mass_id, kind, n_buildings, osm_ids[], geom)`: the cluster. `kind` ∈ hipped | gabled | flat.
- `roof_facet(mass_id, kind, aspect_deg, dir, geom)`: planes. `aspect_deg` is the **downslope bearing** (0 = north, clockwise), i.e. the direction the facet faces. `dir` is the 8-point label. Hipped facets: one per boundary edge, aspect from the facet's interior point to the nearest boundary point. Gabled: one per side of the centreline.
- `roof_shape_line(mass_id, class, geom)`: `ridge` (gable ridge, or a hip-skeleton edge between two facets facing ≥ 150° apart), `hip` (every other skeleton edge), `parapet`.

The table is named `roof_shape_line`, not `roof_line`, because `building.sql` reads and then drops the osm2pgsql table `roof_line`. Re-running `building.sql` after this file would otherwise import the new lines into `building_lines`.

Counts on the bbox: 15,570 facets (15,034 hipped, 536 gabled), average 6 vertices. Lines: 22,353 hip and 7,340 ridge pieces (merged per mass, but not per edge) and 364 parapets. Facet aspect is spread over all eight directions, with S 2,517 and N 2,466 leading.

## 7. Visual probe

Preview preset `--layers roofs` (new `rust/srk-render/src/roof_shapes.rs`; wiring in `layers.rs` and `main.rs`). Paper, footprints, facets tinted by the NW-light term, ridge/hip/parapet lines. It is a probe, not a style.

Rendered with `docs/design-research/tools/render_scenes.sh roofs /tmp/roofs`; scenes a, b, d and e were checked by eye. Scenes c and f rendered but were not reviewed.

| Herrfurthplatz (a) | Schillerpromenade (b) | Richardplatz (e) |
| --- | --- | --- |
| ![](roof-shapes/a-herrfurthplatz.jpg) | ![](roof-shapes/b-schillerpromenade.jpg) | ![](roof-shapes/e-richardplatz.jpg) |

- **Works:** Gründerzeit perimeter blocks (b) read as blocks with a ridge per wing and hips at the corners. Courtyard slopes inward. Tagged pyramids (a, e) and gabled strips (e) come out right.
- **Courtyard blocks (d) are flat, and that is correct for the data:** the six-storey apartment blocks there are tagged `roof:shape=flat`.
- **Does not work well:** small bowtie facets where narrow courtyard wings meet (b, centre); L-shaped gables are approximate; at z19 the ridge lines are only slightly heavier than the outlines, so a style needs a clearly heavier ridge stroke than the base line width.

## 8. How each style should use the data (not yet integrated)

Both snippets assume `roof_shapes::lit_factor(aspect_deg)` is available. It is in `roof_shapes.rs` and returns 1 for facets facing the NW light and 0 for facets facing away.

### Ink (`style_ink.rs`, `draw_buildings`)

Sketch, not compiled: `w`, `h` are the tile's pixel size and `ink`, `lw`, `pm`, `ctx` are the locals of `draw_buildings`.

Replace the current ridge from `ST_OrientedEnvelope` and the single hatch with per-facet hatching. Lines run **along the ridge**, which is perpendicular to the downslope direction, so each facet gets `aspect + 90°`. Shaded facets get a second hatch at a different angle (cross-hatch, as now).

```rust
// in draw_buildings, after the footprint fill
let facets = ctx.polygons(
    "mass_id::bigint AS id, kind AS class, dir AS sub, aspect_deg AS num",
    "roof_facet",
    "",
)?;
for f in &facets {
    let shade = 1.0 - crate::roof_shapes::lit_factor(f.num);
    let Some(mask) = mask_of(&ctx, &[&f.geom]) else { continue };
    // lit facets: one hatch along the ridge; shaded facets: second hatch 60° off
    let ridge_deg = (f.num as f32) + 90.0;
    if let Some(p) = hatch_path(&ctx, 5.0, ridge_deg, 0.0, 0.0, w, h) {
        line(pm, &p, &paint(with_alpha(ink, 0.25 + 0.2 * shade)), &stroke(lw * 0.5), Some(&mask));
    }
    if shade > 0.5 {
        if let Some(p) = hatch_path(&ctx, 5.0, ridge_deg + 60.0, 0.0, 0.0, w, h) {
            line(pm, &p, &paint(with_alpha(ink, 0.3)), &stroke(lw * 0.5), Some(&mask));
        }
    }
}
// ridges and hips (replace the ST_OrientedEnvelope ridge)
let lines = ctx.lines("mass_id::bigint AS id, class, '' AS sub, 0::float8 AS num", "roof_shape_line", "")?;
// class "ridge": heavy line (lw * 1.2); class "hip": thin (lw * 0.5); class "parapet": hairline.
```

Check `hatch_path`'s angle convention before merging: `aspect` is a map bearing (0 = north = up), so verify the screen-angle mapping in `style_kit.rs`. Keep the hatch anchoring world-based so tiles stay seamless. Painter's order and the paper fill of the footprint stay as they are.

### Landscape architecture (`style_la.rs`)

White buildings and a crisp outline stay. Add:

- **Facet shading:** a very light tone per facet, e.g. `with_alpha(ink, 0.04 + 0.12 * shade)` on the white roof. The SE shadow already encodes the same NW light.
- **Ridge hairline:** `class = 'ridge'` only, `stroke(0.35 px)`, low opacity. No hips and no parapets: a landscape plan shows roofs as planes, not construction lines.
- Do not draw the `hip` class at all; the facet tone already shows the planes.

## 9. Reproduce

```bash
# DB: the dev container must be running (localhost:5433)
docker exec -i strassenraumkarte-db-1 psql -U postgres -d strassenraumkarte -X -v ON_ERROR_STOP=1 < data/processing/sql/roof_shape.sql
cd rust/srk-render && cargo build --release
cd ../.. && docs/design-research/tools/render_scenes.sh roofs /tmp/roofs
```

## 10. Next steps

1. **Lua import:** add `roof:direction`, `roof:orientation` to `building` in `data/lua/osm_import.lua`, so skillions and some gables become exact. Needs a re-import.
2. **Narrow courtyard wings:** drop facets below ~3 m² *before* polygonizing (merge them into the neighbour) instead of leaving bowties. Or raise the closing radius only for courtyard holes.
3. **L-shaped gables:** decompose into rectangles, then gable each; or use the skeleton with the short ends clipped.
4. **Valleys:** classify skeleton edges that start at a reflex vertex as `valley`; the ink style can draw them dashed.
5. **Speed:** the facet and line queries dominate; the `ST_DWithin` per line piece could become a single join on the skeleton edges.
6. **Integration:** after the branches merge, implement section 8 in `style_ink.rs` and `style_la.rs`, and check the render at z17 and z19 with the seam check.
