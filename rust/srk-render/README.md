# srk-render

Rust XYZ tile renderer for the Straßenraumkarte evaluation.

## Presets (`--layers`)

| Preset | Purpose |
| --- | --- |
| `full-approx` (**default**) | Paint stack: landuse → pitch → water → waterway → path/service → highway_area → buildings (SE drop-shadow) → trees (soft crowns). No labels, SVG, or full QGIS effect stacks. |
| `highway_area` | Isolate: SimpleFill class rules only (parity smoke vs QGIS `--layers highway_area`). |

## Build

```bash
export PATH="$HOME/.cargo/bin:$PATH"
# Needs libwebp (Homebrew: `brew install webp`)
cd rust/srk-render
cargo build --release
```

## Render one tile

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export DB_HOST=localhost DB_PORT=5433 DB_USER=postgres DB_NAME=strassenraumkarte
export PGPASSWORD=postgres

# Full approximate stack — default WebP q90
./target/release/srk-render \
  --tiles 17/70422/43011 \
  --layers full-approx \
  --out audit/tile-regression/runs/full-approx-local/rust

# Lossless PNG for pixelmatch / regression harness
./target/release/srk-render \
  --tiles 17/70422/43008 \
  --layers highway_area \
  --out /tmp/srk-one-tile-cand \
  --format png
```

Also supports `--bbox xmin,ymin,xmax,ymax --zmin 15 --zmax 18` (writes `timing.json`).

## Metatile

`--metatile N` (default **1** for harness; farm benches use **8**) packs up to N×N core tiles per paint pass, with `--gutter` extra tiles rendered then cropped (default **0** for farm throughput; use `--gutter 1` to match QGIS `render/xyz_tiles.py` edge bleed). `--tiles` mode uses one metatile per listed tile (N ignored for packing).

## Output formats

| `--format` | Use |
| --- | --- |
| `webp` (**default**, `--quality 90`) | Production-shaped tiles; much smaller than PNG |
| `png` | Regression harness / pixelmatch (lossless) |

## Notes

- Tile math matches `render/xyz_tiles.py` (`ORIGIN_SHIFT`, 256 px, EPSG:3857, background `#ededed`).
- Geometries clipped with `ST_ClipByBox2D` in EPSG:3857; `ORDER BY coalesce(layer,0)` where present.
- **Deferred:** PAL labels, SvgMarker, full effect stacks, symbol levels, blend modes.
