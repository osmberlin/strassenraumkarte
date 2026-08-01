import type { FilterSpecification, LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { FOREST_CLASSES, WATER_FILL, WATER_INNER, WATERWAY_LINE } from '../colors'
import { dropShadow, innerShadow, outerGlow } from '../effects'
import { base, landuseFillMatch } from '../expr'
import { metresToPixelsFromProp } from '../metres'

/** Ground: landuse (+ forest effects), water body, waterway. */
export function groundLayers(): LayerSpecification[] {
  const landuseBase = base('landuse', 15)
  const waterBase = base('water_body_dissolved', 15)
  const forestFilter = [
    'in',
    ['get', 'class'],
    ['literal', [...FOREST_CLASSES]],
  ] as FilterSpecification

  const layers: LayerSpecification[] = []

  layers.push(
    ...dropShadow('landuse-forest', { ...landuseBase, filter: forestFilter }, {
      blurM: 1,
      offsetM: 0.4,
      angleDeg: 40,
      color: '#232323',
      opacity: 0.33,
    }),
  )

  layers.push({
    id: 'landuse-fill',
    type: 'fill',
    ...landuseBase,
    paint: {
      'fill-color': landuseFillMatch(),
      'fill-opacity': 1,
    },
  })

  layers.push(
    ...outerGlow('landuse-forest', { ...landuseBase, filter: forestFilter }, {
      blurM: 0.75,
      color: '#c8dbb6',
      opacityInner: 0.35,
      opacityOuter: 0.2,
    }),
  )

  layers.push({
    id: 'water-fill',
    type: 'fill',
    ...waterBase,
    paint: {
      'fill-color': WATER_FILL,
      'fill-opacity': 1,
    },
  })

  layers.push(
    ...innerShadow('water', waterBase, {
      blurM: 4,
      color: WATER_INNER,
      opacity: 0.55,
    }),
  )

  const waterwayWidth = metresToPixelsFromProp('width', 1.5)

  layers.push({
    id: 'waterway-line',
    type: 'line',
    ...base('waterway_clipped', 15),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': WATERWAY_LINE,
      'line-width': waterwayWidth,
    },
  })

  layers.push({
    id: 'waterway-tunnel',
    type: 'line',
    ...base('waterway_clipped', 15, [
      'any',
      ['==', ['get', 'tunnel'], 'yes'],
      ['==', ['get', 'covered'], 'yes'],
    ]),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': WATERWAY_LINE,
      'line-opacity': 0.55,
      'line-dasharray': [1, 1.5],
      'line-width': waterwayWidth,
    },
  })

  return layers
}
