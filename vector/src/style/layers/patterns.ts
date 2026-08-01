/**
 * G8 — Symbol patterns (construction / outdoor_seating hatch + dog-park paw).
 *
 * Uses `landuse` polygons filtered by `class`. Patterns are baked into the
 * build-time sprite at QGIS metres @ z18 (G0.4); paw displacement dropped.
 */
import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { base } from '../expr'
import { metresToPixels } from '../metres'

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

/** QGIS dog park minScale 6000 ≈ z16.5 */
const DOG_PARK_MINZ = 17

export function patternLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  // construction — hatch fill + orange outline (α 0.65, 0.4 m)
  layers.push({
    id: 'construction-hatch',
    type: 'fill',
    ...base('landuse', 15, f(['==', ['get', 'class'], 'construction'])),
    paint: {
      'fill-pattern': 'patterns/construction-hatch',
    },
  })
  layers.push({
    id: 'construction-outline',
    type: 'line',
    ...base('landuse', 15, f(['==', ['get', 'class'], 'construction'])),
    layout: { 'line-cap': 'square', 'line-join': 'bevel' },
    paint: {
      'line-color': '#ff5300',
      'line-opacity': 0.65,
      'line-width': metresToPixels(0.4),
    },
  })

  // outdoor_seating — QGIS LinePatternFill only (no SimpleFill): 1.2 m @ 135°, #dce6cb α 0.67
  layers.push({
    id: 'outdoor_seating-hatch',
    type: 'fill',
    ...base('landuse', 15, f(['==', ['get', 'class'], 'outdoor_seating'])),
    paint: {
      'fill-pattern': 'patterns/outdoor-seating-hatch',
    },
  })

  // dog park — paw fill-pattern above ~z16.5
  layers.push({
    id: 'dog_park-paws',
    type: 'fill',
    ...base('landuse', DOG_PARK_MINZ, f(['==', ['get', 'class'], 'dog_park'])),
    paint: {
      'fill-pattern': 'patterns/dog-park-paw',
    },
  })

  return layers
}
