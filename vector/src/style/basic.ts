import type { LayerSpecification, StyleSpecification } from 'maplibre-gl'

import { LAYERS, SOURCE_ID } from '../../layers'

/** Prep style: areas = transparent blue, lines = purple, points = red. */
const FILL = 'rgba(30, 100, 220, 0.35)'
const FILL_OUTLINE = 'rgba(30, 100, 220, 0.7)'
const LINE = '#7c3aed'
const CIRCLE = '#dc2626'

function paintLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

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

/**
 * @param tileTemplate HTTP template with {z}/{x}/{y}, e.g. `/mvt/{z}/{x}/{y}.mvt`
 */
export function buildBasicStyle(tileTemplate: string): StyleSpecification {
  return {
    version: 8,
    name: 'Straßenraumkarte vector (basic)',
    sources: {
      [SOURCE_ID]: {
        type: 'vector',
        tiles: [tileTemplate],
        minzoom: 15,
        maxzoom: 18,
      },
    },
    layers: [
      {
        id: 'background',
        type: 'background',
        paint: { 'background-color': '#ededed' },
      },
      ...paintLayers(),
    ],
  }
}

/** Default map view — Berlin-Neukölln starter area (docker BBOX centre). */
export const DEFAULT_VIEW = {
  longitude: 13.4222,
  latitude: 52.4768,
  zoom: 16,
} as const
