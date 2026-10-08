/**
 * Style builder — emits a MapLibre StyleSpecification for the vector channel.
 */
import type {
  LayerSpecification,
  SpriteSpecification,
  StyleSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { MAP_MAX_ZOOM, MAP_MIN_ZOOM } from '../../layers'
import { qgisLayerSpecs } from './qgis'
import { GLYPHS_URL, SOURCE_ID, spriteSources, vectorSourceSpec, type SourceUrlOptions } from './source'

export type BuildStyleOptions = SourceUrlOptions & {
  sprite?: SpriteSpecification
  glyphs?: string
  name?: string
  backgroundColor?: string
}

const BACKGROUND = '#ededed'

/** Full style document (sources + layers) for validation and non-React use. */
export function buildStyle(options: BuildStyleOptions): StyleSpecification {
  const {
    url,
    sprite = spriteSources(),
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

  return {
    version: 8,
    name,
    metadata: {
      'strassenraumkarte:map-minzoom': MAP_MIN_ZOOM,
      'strassenraumkarte:map-maxzoom': MAP_MAX_ZOOM,
    },
    glyphs,
    sprite,
    sources: {
      [SOURCE_ID]: vectorSourceSpec({ url }),
    },
    layers,
  }
}

export function emptyBaseStyle(
  options: Pick<BuildStyleOptions, 'name' | 'glyphs' | 'backgroundColor' | 'sprite'> = {},
): StyleSpecification {
  const {
    name = 'Straßenraumkarte vector',
    glyphs = GLYPHS_URL,
    sprite = spriteSources(),
    backgroundColor = BACKGROUND,
  } = options

  return {
    version: 8,
    name,
    glyphs,
    sprite,
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
