import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import {
  BUILDING_LINES,
  BUILDING_PARTS_FILL,
  BUILDING_SHADE_FILL,
} from '../colors'
import { dropShadow } from '../effects'
import { base } from '../expr'
import { metresToPixels } from '../metres'

/** Buildings: shade → parts (sorted by height) → footprint → lines. */
export function buildingLayers(): LayerSpecification[] {
  const shadeBase = base('building_shade', 15)
  const partsBase = base('building_parts_dissolved_height', 15)
  const buildingBase = base('building', 15)
  const linesBase = base('building_lines', 15)

  const layers: LayerSpecification[] = []

  layers.push(
    ...dropShadow('building-shade', shadeBase, {
      blurM: 1.6,
      offsetM: 0.4,
      angleDeg: 40,
      color: '#232323',
      opacity: 0.138,
    }),
  )

  layers.push({
    id: 'building-shade-fill',
    type: 'fill',
    ...shadeBase,
    paint: {
      'fill-color': BUILDING_SHADE_FILL,
      'fill-opacity': 1,
      'fill-outline-color': BUILDING_SHADE_FILL,
    },
  })

  layers.push(
    ...dropShadow('building-parts', partsBase, {
      blurM: 2,
      offsetM: 1,
      angleDeg: 40,
      color: '#232323',
      opacity: 0.4,
    }),
  )

  layers.push({
    id: 'building-parts-fill',
    type: 'fill',
    ...partsBase,
    paint: {
      'fill-color': BUILDING_PARTS_FILL,
      'fill-opacity': 0.7,
      'fill-outline-color': '#e8c8c8',
    },
    // Lower height drawn first (under taller parts).
    layout: {
      'fill-sort-key': ['coalesce', ['get', 'height'], 0],
    } as never,
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
