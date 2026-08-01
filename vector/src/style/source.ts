/**
 * Vector source + glyph/sprite URLs for the MapLibre style.
 *
 * Sprite is optional until `scripts/build-sprite.ts` lands (w5).
 * Glyphs: MapLibre demotiles (Open Sans / Arial Unicode MS) — confirmed for G12.
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
 * Glyph endpoint for G12 labels. MapLibre demotiles serves the Open Sans /
 * Arial Unicode MS stack used in the style (HTTP 200 for the PBF ranges we
 * request). Swap to a self-hosted OpenMapTiles-compatible font when offline
 * or production pinning is required — QGIS uses DejaVu Sans Condensed.
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
