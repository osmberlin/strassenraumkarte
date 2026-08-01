import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { base } from '../expr'

/** Labels — housenumbers + symbol layers along exported placement lines. */
export function labelLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  // QGIS housenumber: addr:housenumber, DejaVu 7.5 pt #b7b7b7, buffer #d8d5d5 α 0.75,
  // visible above ~1:1000 → MapLibre minzoom 18 (overzoom from tippecanoe z17).
  layers.push({
    id: 'label-housenumber',
    type: 'symbol',
    ...base('housenumber', 18),
    layout: {
      'text-field': ['coalesce', ['get', 'addr:housenumber'], ''],
      'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
      // 7.5 pt @ 96 DPI ≈ 10 px
      'text-size': 10,
      'text-optional': true,
      'text-allow-overlap': false,
    },
    paint: {
      'text-color': '#b7b7b7',
      'text-halo-color': 'rgba(216,213,213,0.75)',
      'text-halo-width': 1.5,
    },
  })

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
