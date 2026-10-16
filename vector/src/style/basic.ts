import type {
  CircleLayerSpecification,
  FillLayerSpecification,
  LineLayerSpecification,
  StyleSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { LAYERS, type LayerDef } from '../../layers'
import { PREP_COLORS } from './legend'
import { CORE_PAINT_ORDER } from './order'
import { GLYPHS_URL, SOURCE_ID } from './source'

export { SOURCE_ID }

const FILL = PREP_COLORS.fill
const FILL_OUTLINE = PREP_COLORS.fillOutline
const LINE = PREP_COLORS.line
const CIRCLE = PREP_COLORS.circle

/**
 * Prep style: areas = transparent blue, lines = purple, points = red.
 *
 * Layer `minzoom` matches tippecanoe `-Z`. No layer `maxzoom` (overscaled parent tiles).
 * Paint order follows `CORE_PAINT_ORDER`. OSM bucket expansion is deferred to w4c.
 */
export const BASE_STYLE: StyleSpecification = {
  version: 8,
  name: 'Straßenraumkarte vector (basic)',
  glyphs: GLYPHS_URL,
  sources: {},
  layers: [
    {
      id: 'background',
      type: 'background',
      paint: { 'background-color': PREP_COLORS.background },
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

function paintOrderIndex(id: string): number {
  const idx = (CORE_PAINT_ORDER as readonly string[]).indexOf(id)
  return idx === -1 ? CORE_PAINT_ORDER.length + LAYERS.findIndex((l) => l.id === id) : idx
}

function sortedLayerDefs(): LayerDef[] {
  return [...LAYERS].sort((a, b) => paintOrderIndex(a.id) - paintOrderIndex(b.id))
}

function layerSpec(def: LayerDef): BasicLayerSpec {
  if (def.paint === 'fill') {
    return {
      id: `${def.id}-fill`,
      type: 'fill',
      source: SOURCE_ID,
      'source-layer': def.id,
      minzoom: def.minzoom,
      paint: {
        'fill-color': FILL,
        'fill-opacity': 0.45,
        'fill-outline-color': FILL_OUTLINE,
      },
    }
  }
  if (def.paint === 'line') {
    return {
      id: `${def.id}-line`,
      type: 'line',
      source: SOURCE_ID,
      'source-layer': def.id,
      minzoom: def.minzoom,
      paint: {
        'line-color': LINE,
        'line-width': 1.5,
      },
    }
  }
  return {
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
  }
}

/** Declarative layer props for react-map-gl <Layer />, in QGIS paint order. */
export function basicLayerSpecs(): BasicLayerSpec[] {
  return sortedLayerDefs().map(layerSpec)
}

/** Default map view — Berlin-Neukölln starter area (docker BBOX centre). */
export const DEFAULT_VIEW = {
  longitude: 13.4222,
  latitude: 52.4768,
  zoom: 16,
} as const
