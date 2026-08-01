import type { CircleLayerSpecification, FillLayerSpecification, LineLayerSpecification, StyleSpecification } from 'maplibre-gl'

import { LAYERS, SOURCE_ID } from '../../layers'

/**
 * Prep style: areas = transparent blue, lines = purple, points = red.
 *
 * Layer `minzoom` matches tippecanoe `-Z` (features first appear in those tiles).
 * No layer `maxzoom`: paint while features are present in the current/overscaled tile.
 * In the joined archive, layers tippecanoe’d only to e.g. z16 (ground) are absent from
 * z17+ tiles, so they drop out above their tippecanoe maxzoom — that is expected.
 */
const FILL = 'rgba(30, 100, 220, 0.35)'
const FILL_OUTLINE = 'rgba(30, 100, 220, 0.7)'
const LINE = '#7c3aed'
const CIRCLE = '#dc2626'

export { SOURCE_ID }

/** Base style without sources/layers — data comes from declarative <Source>/<Layer>. */
export const BASE_STYLE: StyleSpecification = {
  version: 8,
  name: 'Straßenraumkarte vector (basic)',
  sources: {},
  layers: [
    {
      id: 'background',
      type: 'background',
      paint: { 'background-color': '#ededed' },
    },
  ],
}

export type BasicLayerSpec =
  | (Pick<FillLayerSpecification, 'id' | 'type' | 'source' | 'source-layer' | 'minzoom' | 'paint'> & {
      type: 'fill'
    })
  | (Pick<LineLayerSpecification, 'id' | 'type' | 'source' | 'source-layer' | 'minzoom' | 'paint'> & {
      type: 'line'
    })
  | (Pick<CircleLayerSpecification, 'id' | 'type' | 'source' | 'source-layer' | 'minzoom' | 'paint'> & {
      type: 'circle'
    })

/** Declarative layer props for react-map-gl <Layer />. */
export function basicLayerSpecs(): BasicLayerSpec[] {
  const layers: BasicLayerSpec[] = []

  for (const def of LAYERS) {
    if (def.paint === 'fill') {
      layers.push({
        id: `${def.id}-fill`,
        type: 'fill',
        source: SOURCE_ID,
        'source-layer': def.id,
        minzoom: def.minzoom,
        paint: {
          'fill-color': FILL,
          'fill-outline-color': FILL_OUTLINE,
        },
      })
    } else if (def.paint === 'line') {
      layers.push({
        id: `${def.id}-line`,
        type: 'line',
        source: SOURCE_ID,
        'source-layer': def.id,
        minzoom: def.minzoom,
        paint: {
          'line-color': LINE,
          'line-width': 1.5,
        },
      })
    } else {
      layers.push({
        id: `${def.id}-circle`,
        type: 'circle',
        source: SOURCE_ID,
        'source-layer': def.id,
        minzoom: def.minzoom,
        paint: {
          'circle-color': CIRCLE,
          'circle-radius': 3,
          'circle-opacity': 0.9,
        },
      })
    }
  }

  return layers
}

/** Default map view — Berlin-Neukölln starter area (docker BBOX centre). */
export const DEFAULT_VIEW = {
  longitude: 13.4222,
  latitude: 52.4768,
  zoom: 16,
} as const
