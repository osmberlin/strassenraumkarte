import type {
  ExpressionSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { BUILDING_LINES, BUILDING_PARTS_FILL } from '../colors'
import { base } from '../expr'
import { metresToPixels } from '../metres'

/** QGIS enableorderby height ascending — shorter parts under taller. */
const PARTS_SORT_KEY = [
  'coalesce',
  ['get', 'height'],
  0,
] as ExpressionSpecification

/**
 * Buildings: parts (sorted by height) → footprint → lines.
 *
 * QGIS `building_shade` uses drawSource OFF + Gaussian dropShadow of extruded
 * shade polygons. MapLibre cannot blur fills; painting shade/parts drop shadows
 * reads as a hard black SE slab — skipped (known deviation vs QGIS/Rust).
 *
 * Roof-shape gradients (#990003 magma / Shapeburst) are intentionally skipped —
 * unfinished QGIS experiment (see docs/maplibre-style-groups.md G10).
 */
export function buildingLayers(): LayerSpecification[] {
  const partsBase = base('building_parts_dissolved_height', 15)
  const buildingBase = base('building', 15)
  const linesBase = base('building_lines', 15)

  const layers: LayerSpecification[] = []

  layers.push({
    id: 'building-parts-fill',
    type: 'fill',
    ...partsBase,
    layout: {
      'fill-sort-key': PARTS_SORT_KEY,
    },
    paint: {
      'fill-color': BUILDING_PARTS_FILL,
      'fill-opacity': 0.7,
    },
  })

  layers.push({
    id: 'building-parts-outline',
    type: 'line',
    ...partsBase,
    layout: {
      'line-sort-key': PARTS_SORT_KEY,
    },
    paint: {
      'line-color': '#e8c8c8',
      'line-width': metresToPixels(0.015),
    },
  })

  layers.push({
    id: 'building-fill',
    type: 'fill',
    ...buildingBase,
    paint: {
      'fill-color': BUILDING_PARTS_FILL,
      'fill-opacity': 0.85,
      'fill-outline-color': '#d4b0b0',
    },
  })

  for (const [cls, metres] of [
    ['footline_covered', 0.2],
    ['footline_uncovered', 0.05],
    ['part_outline', 0.02],
    ['roof_edge', 0.04],
    ['roof_ridge', 0.04],
  ] as const) {
    layers.push({
      id: `building-lines-${cls}`,
      type: 'line',
      ...linesBase,
      filter: ['==', ['get', 'class'], cls],
      paint: {
        'line-color': BUILDING_LINES,
        'line-width': metresToPixels(metres),
        ...(cls === 'footline_covered' ? { 'line-dasharray': [2, 2] } : {}),
      },
    })
  }

  return layers
}
