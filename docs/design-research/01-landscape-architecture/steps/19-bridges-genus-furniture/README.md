# LA 19 — bridges, genus trees, play and furniture symbols

New module [`style_la_extra.rs`](../../../../../rust/srk-render/src/style_la_extra.rs) (child of `style_la.rs`).

- **Bridges** (`bridge` table): soft SE shadow (offset grows with `layer`) onto rails, water and roads below; light deck; crisp parapet outline drawn again on top of the street surface. Street areas are split by `layer`: ground level → bridge → raised areas.
- **Trees per genus**: Tilia (fine-scalloped dome + inner ring), Acer (5–7 lobes with veins), Betula (pale wash, dashed rim, leaf stipple), Quercus (cloud of sub-crowns), Platanus (large disc, ring, long branches), blossom trees (Prunus, Malus, Pyrus, Sorbus …: ring of white dots), Salix (fringe), Carpinus/Fagus/Ulmus (double scallop), pinnate (Robinia, Fraxinus …: radial), conifers (star). Each genus has a fixed palette slot and a default crown diameter used when `diameter_crown` is missing. Only ~500 of 11 500 trees in the import carry `genus`; the rest keep the generic symbols.
- **Play equipment**: sandpits with a timber edge, water basins/channels in water colour, slides as a white chute with outline and ladder rungs, swing frames with seats, seesaws, springers, rotators, posts.
- **Furniture**: benches with a heavy backrest line on the side opposite `direction`; picnic tables with two benches; table tennis with net; bicycle stands as a row of U-shapes (count from `capacity`) oriented across the nearest street (azimuth from SQL, the data has no `direction`); drinking water, Berlin street pumps (`water_well`) and fountains as water circles; fountain areas with a double rim.

Not possible from the current import: `roof:colour` / `building:colour` (columns not imported, see README); parked cars (`data/parking/street_parking_points_processed.geojson` is not generated in this checkout).

**Look at:** `bridge-fountain.jpg` (Hertabrücke z18 over the Ringbahn; Karl-Marx-Platz fountain z19), `sheet-ef.jpg` (Körnerpark benches and bike stands), `detail-play.jpg` (scene D playground).
