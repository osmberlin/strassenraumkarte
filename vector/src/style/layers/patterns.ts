/**
 * G8 — Symbol patterns (construction hatch + dog-park paw grid).
 *
 * Both use `landuse` polygons filtered by `class`. Patterns are baked into the
 * build-time sprite (`patterns/construction-hatch`, `patterns/dog-park-paw`)
 * at QGIS metres @ z18 (G0.4); paw displacement dropped.
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
