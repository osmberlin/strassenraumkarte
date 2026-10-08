/**
 * Vector source + glyph/sprite URLs for the MapLibre style.
 *
 * Sprites come from `scripts/build-sprite.ts` (`bun run sprite`).
 * Glyphs: MapLibre demotiles (Open Sans / Arial Unicode MS) — confirmed for G12.
 */
import type {
  SpriteSpecification,
  VectorSourceSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { SYMBOL_SPRITE_ID } from './sprite-icons'
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

/** Marker icon sheet (`symbols:*` ids, lossless RGBA) — see `sprite-icons.ts`. */
export const SYMBOL_SPRITE_PATH = '/sprites/strassenraumkarte-symbols'

/** Resolve sprite to an absolute URL (MapLibre 6 rejects root-relative sprite). */
export function absoluteSpriteUrl(origin = 'http://127.0.0.1:5177', spritePath = SPRITE_PATH): string {
  if (spritePath.startsWith('http://') || spritePath.startsWith('https://')) return spritePath
  return `${origin.replace(/\/$/, '')}${spritePath}`
}

/** Style `sprite`: textures/patterns (default, unprefixed ids) + marker icons (`symbols:`). */
export function spriteSources(origin?: string): SpriteSpecification {
  return [
    { id: 'default', url: absoluteSpriteUrl(origin) },
    { id: SYMBOL_SPRITE_ID, url: absoluteSpriteUrl(origin, SYMBOL_SPRITE_PATH) },
  ]
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
