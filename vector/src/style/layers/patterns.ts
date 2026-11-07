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
import { metresToPixels, scaleToZoom } from '../metres'

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

/** QGIS dog park minScale 6000 */
const DOG_PARK_MINZ = scaleToZoom(6000)

export function patternLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  // construction — QGIS layer opacity 0.2: yellow SimpleFill #dee553, dark hatch (α 0.5),
  // orange outline. Each is multiplied by the layer opacity.
  layers.push({
    id: 'construction-fill',
    type: 'fill',
    ...base('landuse', 15, f(['==', ['get', 'class'], 'construction'])),
    paint: {
      'fill-color': '#dee553',
      'fill-opacity': 0.2,
    },
  })
  layers.push({
    id: 'construction-hatch',
    type: 'fill',
    ...base('landuse', 15, f(['==', ['get', 'class'], 'construction'])),
    paint: {
      'fill-pattern': 'patterns/construction-hatch',
      'fill-opacity': 0.2,
    },
  })
  layers.push({
    id: 'construction-outline',
    type: 'line',
    ...base('landuse', 15, f(['==', ['get', 'class'], 'construction'])),
    layout: { 'line-cap': 'square', 'line-join': 'bevel' },
    paint: {
      'line-color': '#ff5300',
      'line-opacity': 0.2,
      'line-width': metresToPixels(0.6),
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

  // dog park — paw fill-pattern below 1:6000
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
