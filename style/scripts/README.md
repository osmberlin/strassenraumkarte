# Style scripts

PyQGIS helpers that dump machine-readable artefacts from `style/strassenraumkarte.qgz`.

## Prerequisites

Same headless QGIS env as tile rendering:

```bash
source render/qgis_env.sh
# expects QGIS_APP (default /Applications/QGIS-final-4_0_2.app) and PYTHON
```

Generated files land in `style/generated/` (gitignored except `.gitkeep`).

## `dump-style.py`

Loads the `.qgz` via `QgsProject.read()` and writes:

| Output | Contents |
| --- | --- |
| `style/generated/style-inventory.md` | Authoritative maplayer / renderer / symbol-layer / effect / labeling / opacity counts |
| `style/generated/expression-surface.json` | Distinct expression functions + `@variables` with usage counts |
| `style/generated/style-ir.json` | Trimmed IR — default **`highway_area` only** (all OSM-layer duplicates) |

```bash
source render/qgis_env.sh
python3 style/scripts/dump-style.py

# custom project / out dir
python3 style/scripts/dump-style.py \
  --project style/strassenraumkarte.qgz \
  --out-dir style/generated \
  --layer highway_area

# full IR for every map layer (large — optional)
python3 style/scripts/dump-style.py --ir-all
```

Wall clock on this host is typically tens of seconds (project load + walk). Prefer
`--layer highway_area` while iterating the Rust slice; use `--ir-all` when expanding
coverage or retiring hand counts in `docs/maplibre-style-groups.md`.
