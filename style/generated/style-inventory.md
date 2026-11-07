# Style inventory (PyQGIS)

Source: `style/strassenraumkarte.qgz`  
Generated: 2026-08-01T15:29:13Z  
Dump wall clock: 3.4s  

Authoritative counts from a loaded `QgsProject` (not raw XML). Resolves the data-defined-property / opacity disagreements between XML parses.

Counts walk nested `subSymbol()` trees (MarkerLine / CentroidFill / …). Effect types are `QgsPaintEffect.type()` strings; `drawSource` is the stack’s pass-through paint and is listed separately from shadows/glows.

## Totals

| Metric | Count |
| --- | ---: |
| `maplayer` entries | 256 |
| Unique layer names | 64 |
| Layers with labeling enabled (maplayer entries) | 30 |
| Unique names with labeling enabled | 12 |
| Active data-defined properties | 3604 |
| Layers with opacity ≠ 1.0 (maplayer entries) | 100 |
| Unique names with opacity ≠ 1.0 | 22 |

## Renderer types

| Renderer | Count |
| --- | ---: |
| QgsRuleBasedRenderer | 95 |
| QgsSingleSymbolRenderer | 94 |
| QgsCategorizedSymbolRenderer | 60 |
| QgsNullSymbolRenderer | 7 |

## Symbol layer classes

| Class | Count |
| --- | ---: |
| QgsSimpleLineSymbolLayer | 576 |
| QgsSimpleMarkerSymbolLayer | 452 |
| QgsSimpleFillSymbolLayer | 431 |
| QgsSvgMarkerSymbolLayer | 185 |
| QgsRasterFillSymbolLayer | 133 |
| QgsMarkerLineSymbolLayer | 59 |
| QgsLinePatternFillSymbolLayer | 44 |
| QgsCentroidFillSymbolLayer | 42 |
| QgsHashedLineSymbolLayer | 42 |
| QgsRasterMarkerSymbolLayer | 25 |
| QgsPointPatternFillSymbolLayer | 15 |
| QgsFontMarkerSymbolLayer | 14 |
| QgsShapeburstFillSymbolLayer | 4 |
| QgsGradientFillSymbolLayer | 3 |

## Enabled paint effects (by type string)

| Effect type | Count |
| --- | ---: |
| drawSource | 137 |
| dropShadow | 74 |
| innerShadow | 13 |
| outerGlow | 7 |
| innerGlow | 2 |

**Enabled effects total:** 233  
**Shadows/glows only (excl. drawSource):** 96

## Blend modes (non-SourceOver)

| Mode | Count |
| --- | ---: |
| Multiply | 2 |
| Screen | 1 |

## Unique layer names (alphabetical)

- `barrier_node` ×7
- `barrier_polygon` ×7
- `barrier_way` ×7
- `bridge` ×7
- `bridge_shade` ×7
- `building_lines` ×1
- `building_parts_dissolved_height` ×1
- `building_shade` ×1
- `construction` ×1
- `dog park` ×1
- `entrance` ×1
- `feature_node (foreground) Kopie` ×1
- `feature_node (middleground)` ×7
- `feature_polygon (background)` ×7
- `feature_polygon (middleground)` ×7
- `feature_way (background)` ×7
- `feature_way (middleground)` ×7
- `highway_area` ×7
- `housenumber` ×1
- `label landuse` ×1
- `label water body` ×1
- `label_highway` ×1
- `label_waterway` ×1
- `landscape_node` ×1
- `landscape_way` ×1
- `landuse` ×1
- `landuse surface` ×1
- `parking cars` ×1
- `path (way, casing)` ×7
- `path (way, fill)` ×7
- `pitch` ×1
- `pitch surface` ×1
- `pitch_markings` ×1
- `place_node` ×1
- `place_polygon` ×1
- `playground_node` ×7
- `playground_polygon (except sandpit)` ×7
- `playground_way` ×7
- `railway profile` ×7
- `railway tie` ×7
- `railway_node` ×7
- `road_marking_node` ×7
- `road_marking_polygon` ×7
- `road_marking_way` ×7
- `roof shape` ×1
- `sandpit` ×1
- `scrub (width shade)` ×1
- `separation` ×7
- `service` ×7
- `tactile_paving` ×7
- `tree crown` ×1
- `trunk` ×1
- `water body` ×1
- `water body (depth effect)` ×1
- `water_body (simple backup)` ×1
- `waterway_clipped` ×1
- `wetland` ×1
- `z14` ×7
- `z15` ×7
- `z16` ×7
- `z17` ×7
- `z18` ×7
- `z19` ×7
- `z20` ×7
