/**
 * Validate the built MapLibre style (exit non-zero on errors).
 *
 * Usage: `bun run validate-style`
 */
import { validateStyleMin } from '@maplibre/maplibre-gl-style-spec'

import { buildStyle } from '../src/style/build-style'

const style = buildStyle({
  url: 'pmtiles://http://127.0.0.1:5177/tiles/strassenraumkarte.pmtiles',
})

const errors = validateStyleMin(style)
if (errors.length > 0) {
  for (const err of errors) {
    console.error(err.message)
  }
  process.exit(1)
}

console.log(`OK — ${style.layers.length} layers, source "${Object.keys(style.sources).join(',')}"`)
