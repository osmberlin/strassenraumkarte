/**
 * MapLibre v6 missing-image resolver for unbounded SVG symbols under style/symbols/.
 *
 * Id conventions accepted:
 *   - `symbols/traffic_signs/DE/foo` → /symbols/traffic_signs/DE/foo.svg
 *   - `symbols/trees/broadleaved` → /symbols/trees/broadleaved.png (also tries .svg)
 * Skips sentinels: '', 'null', 'undefined'.
 */
import type { Map as MapLibreMap } from 'maplibre-gl'

const SENTINELS = new Set(['', 'null', 'undefined', 'none'])

function candidateUrls(id: string): string[] {
  const clean = id.replace(/^\/+/, '').replace(/\.svg$/i, '').replace(/\.png$/i, '')
  // Strip optional `symbols/` prefix duplication
  const pathId = clean.startsWith('symbols/') ? clean : `symbols/${clean}`
  return [`/${pathId}.svg`, `/${pathId}.png`, `/${clean}.svg`, `/${clean}.png`]
}

async function rasterizeSvg(url: string, size = 64): Promise<ImageData | null> {
  try {
    const res = await fetch(url)
    if (!res.ok) return null
    const blob = await res.blob()
    const bitmap = await createImageBitmap(blob)
    const canvas = document.createElement('canvas')
    canvas.width = size
    canvas.height = size
    const ctx = canvas.getContext('2d')
    if (!ctx) return null
    ctx.clearRect(0, 0, size, size)
    ctx.drawImage(bitmap, 0, 0, size, size)
    return ctx.getImageData(0, 0, size, size)
  } catch {
    return null
  }
}

export function installMissingStyleImageResolver(map: MapLibreMap): void {
  map.setMissingStyleImageResolver(async (id) => {
    if (SENTINELS.has(id) || map.hasImage(id)) return

    for (const url of candidateUrls(id)) {
      const image = await rasterizeSvg(url)
      if (!image) continue
      if (map.hasImage(id)) return
      map.addImage(id, image, { pixelRatio: 1 })
      return
    }
    // Leave unresolved — styleimagemissing will still fire for triage.
  })
}
