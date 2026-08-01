/**
 * Vector source + glyph/sprite URLs for the MapLibre style.
 *
 * Sprite is optional until `scripts/build-sprite.ts` lands (w5).
 * Glyphs use MapLibre demotiles until a self-hosted font stack is chosen.
 */
import type { VectorSourceSpecification } from '@maplibre/maplibre-gl-style-spec'

import {
  SOURCE_ID,
  SOURCE_MAXZOOM,
  SOURCE_MINZOOM,
} from '../../layers'

export { SOURCE_ID, SOURCE_MAXZOOM, SOURCE_MINZOOM }

/** Public URL path for the joined PMTiles archive (Vite `public/`). */
export const PMTILES_PATH = '/tiles/strassenraumkarte.pmtiles'

/**
 * Free glyph endpoint for label scaffolding. Replace with a self-hosted
 * OpenMapTiles-compatible font when labels leave the prep style.
 */
export const GLYPHS_URL = 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf'

/** Sprite base path (no extension). MapLibre 6 requires an absolute URL at runtime. */
export const SPRITE_PATH = '/sprites/strassenraumkarte'

/** Resolve sprite to an absolute URL (MapLibre 6 rejects root-relative sprite). */
export function absoluteSpriteUrl(origin = 'http://127.0.0.1:5177'): string {
  if (SPRITE_PATH.startsWith('http://') || SPRITE_PATH.startsWith('https://')) return SPRITE_PATH
  return `${origin.replace(/\/$/, '')}${SPRITE_PATH}`
}

export type SourceUrlOptions = {
  /** Absolute `pmtiles://…` URL from `pmtilesSourceUrl()`, or a TileJSON/pmtiles href. */
  url: string
}

/** MapLibre vector source matching tippecanoe archive zooms (overzoom via map maxZoom). */
export function vectorSourceSpec({ url }: SourceUrlOptions): VectorSourceSpecification {
  return {
    type: 'vector',
    url,
    minzoom: SOURCE_MINZOOM,
    maxzoom: SOURCE_MAXZOOM,
  }
}
