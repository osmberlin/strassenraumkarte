import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { base } from '../expr'

/** Labels — symbol layers along exported placement lines. */
export function labelLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  layers.push({
    id: 'label-highway',
    type: 'symbol',
    ...base('label_highway', 15),
    layout: {
      'symbol-placement': 'line',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
      'text-size': 12,
      'text-max-angle': 25,
      'text-keep-upright': true,
    },
    paint: {
      'text-color': '#dddddd',
      'text-halo-color': 'rgba(168,168,167,0.75)',
      'text-halo-width': 1.2,
    },
  })

  layers.push({
    id: 'label-waterway',
    type: 'symbol',
    ...base('label_waterway', 15),
    layout: {
      'symbol-placement': 'line',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
      'text-size': 12,
    },
    paint: {
      'text-color': '#cdcbea',
      'text-halo-color': 'rgba(171,165,216,0.85)',
      'text-halo-width': 1.2,
    },
  })

  return layers
}
