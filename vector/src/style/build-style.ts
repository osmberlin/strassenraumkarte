/**
 * Style builder — emits a MapLibre StyleSpecification for the vector channel.
 */
import type { LayerSpecification, StyleSpecification } from '@maplibre/maplibre-gl-style-spec'

import { MAP_MAX_ZOOM, MAP_MIN_ZOOM } from '../../layers'
import { qgisLayerSpecs } from './qgis'
import { GLYPHS_URL, SOURCE_ID, vectorSourceSpec, type SourceUrlOptions } from './source'

export type BuildStyleOptions = SourceUrlOptions & {
  includeSprite?: boolean
  sprite?: string
  glyphs?: string
  name?: string
  backgroundColor?: string
}

const BACKGROUND = '#ededed'

/** Full style document (sources + layers) for validation and non-React use. */
export function buildStyle(options: BuildStyleOptions): StyleSpecification {
  const {
    url,
    includeSprite = false,
    sprite,
    glyphs = GLYPHS_URL,
    name = 'Straßenraumkarte vector',
    backgroundColor = BACKGROUND,
  } = options

  const layers: LayerSpecification[] = [
    {
      id: 'background',
      type: 'background',
      paint: { 'background-color': backgroundColor },
    },
    ...qgisLayerSpecs(),
  ]

  const style: StyleSpecification = {
    version: 8,
    name,
    metadata: {
      'strassenraumkarte:map-minzoom': MAP_MIN_ZOOM,
      'strassenraumkarte:map-maxzoom': MAP_MAX_ZOOM,
    },
    glyphs,
    sources: {
      [SOURCE_ID]: vectorSourceSpec({ url }),
    },
    layers,
  }

  if (includeSprite) {
    style.sprite = sprite ?? '/sprites/strassenraumkarte'
  }

  return style
}

export function emptyBaseStyle(
  options: Pick<BuildStyleOptions, 'name' | 'glyphs' | 'backgroundColor'> = {},
): StyleSpecification {
  const {
    name = 'Straßenraumkarte vector',
    glyphs = GLYPHS_URL,
    backgroundColor = BACKGROUND,
  } = options

  return {
    version: 8,
    name,
    glyphs,
    sources: {},
    layers: [
      {
        id: 'background',
        type: 'background',
        paint: { 'background-color': backgroundColor },
      },
    ],
  }
}
