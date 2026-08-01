import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { MARKING_DEFAULT, TREE_CROWN, TREE_SHADOW, TREE_TRUNK } from '../colors'
import { OSM_LAYER_BUCKETS, styleLayerId } from '../order'
import { base, withOsmBucket } from '../expr'
import { metresToPixels, metresToPixelsFromProp } from '../metres'

/** Detail: road markings (per OSM bucket), separation, trees. */
export function detailLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  for (const bucket of OSM_LAYER_BUCKETS) {
    const poly = withOsmBucket('road_marking_polygon', 17, bucket.id)
    layers.push({
      id: styleLayerId('road_marking_polygon', 'fill', bucket.id),
      type: 'fill',
      ...poly,
      paint: {
        'fill-color': [
          'coalesce',
          ['get', 'colour'],
          MARKING_DEFAULT,
        ],
        'fill-opacity': 0.9,
      },
    })

    const way = withOsmBucket('road_marking_way', 17, bucket.id)
    layers.push({
      id: styleLayerId('road_marking_way', 'line', bucket.id),
      type: 'line',
      ...way,
      layout: { 'line-cap': 'butt', 'line-join': 'round' },
      paint: {
        'line-color': ['coalesce', ['get', 'colour'], MARKING_DEFAULT],
        'line-width': metresToPixelsFromProp('width', 0.12),
      },
    })

    const node = withOsmBucket('road_marking_node', 17, bucket.id)
    layers.push({
      id: styleLayerId('road_marking_node', 'circle', bucket.id),
      type: 'circle',
      ...node,
      paint: {
        'circle-color': '#f5f5f5',
        'circle-stroke-color': '#333',
        'circle-stroke-width': 0.5,
        'circle-radius': metresToPixels(0.4),
      },
    })

    const sep = withOsmBucket('separation', 17, bucket.id)
    layers.push({
      id: styleLayerId('separation', 'line', bucket.id),
      type: 'line',
      ...sep,
      paint: {
        'line-color': '#ededed',
        'line-width': metresToPixels(0.35),
      },
    })
  }

  // Trees — circle crowns (graphics optional later). Shadow then crown then trunk.
  const treeBase = base('tree', 17)

  layers.push({
    id: 'tree-crown-shadow',
    type: 'circle',
    ...treeBase,
    paint: {
      'circle-color': TREE_SHADOW,
      'circle-opacity': 0.35,
      'circle-blur': 0.6,
      'circle-radius': metresToPixelsFromProp('diameter_crown', 7),
      'circle-translate': [
        'interpolate',
        ['exponential', 2],
        ['zoom'],
        17,
        ['literal', [2, 2]],
        20,
        ['literal', [4, 4]],
      ],
    } as never,
  })

  layers.push({
    id: 'tree-crown',
    type: 'circle',
    ...treeBase,
    filter: ['!=', ['get', 'natural'], 'tree_stump'],
    paint: {
      'circle-color': TREE_CROWN,
      'circle-opacity': 0.85,
      'circle-blur': 0.35,
      'circle-radius': [
        'interpolate',
        ['exponential', 2],
        ['zoom'],
        17,
        ['*', ['/', ['coalesce', ['get', 'diameter_crown'], 7], 2], metresFactor(17)],
        20,
        ['*', ['/', ['coalesce', ['get', 'diameter_crown'], 7], 2], metresFactor(20)],
      ],
    } as never,
  })

  layers.push({
    id: 'tree-trunk',
    type: 'circle',
    ...treeBase,
    paint: {
      'circle-color': TREE_TRUNK,
      'circle-opacity': 0.75,
      'circle-radius': [
        'interpolate',
        ['exponential', 2],
        ['zoom'],
        17,
        ['*', ['/', ['coalesce', ['get', 'circumference'], 1.57], 6.283185], metresFactor(17)],
        20,
        ['*', ['/', ['coalesce', ['get', 'circumference'], 1.57], 6.283185], metresFactor(20)],
      ],
    } as never,
  })

  return layers
}

function metresFactor(zoom: number, lat = 52.48): number {
  return 2 ** zoom / (78271.51696 * Math.cos((lat * Math.PI) / 180))
}
