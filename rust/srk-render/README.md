# srk-render

Minimal Rust XYZ tile renderer for the Straßenraumkarte evaluation. First vertical slice: **`highway_area`** only (flat SimpleFill + 1 px outline, no effects/labels/SVG).

## Build

```bash
export PATH="$HOME/.cargo/bin:$PATH"
cd rust/srk-render
cargo build --release
```

## Render one tile

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export DB_HOST=localhost DB_PORT=5433 DB_USER=postgres DB_NAME=strassenraumkarte
export PGPASSWORD=postgres
# optional: PGPASSFILE=/tmp/srk-pgpass/.pgpass

./target/release/srk-render \
  --tiles 17/70422/43008 \
  --layers highway_area \
  --out /tmp/srk-one-tile-cand \
  --format png
```

Output: `/tmp/srk-one-tile-cand/17/70422/43008.png` (256×256, background `#ededed`, EPSG:3857 tile math matching `render/xyz_tiles.py`).

## Notes

- Fill colours approximate the QGIS / MapLibre `area:highway` palette (`#a8a8a7` road/parking, `#e1e3bd` footway, …). Surface textures and the z14–z20 blur stack are out of scope for this slice.
- Geometries are clipped with `ST_ClipByBox2D` in EPSG:3857.
