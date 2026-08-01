/**
 * MapLibre v6 missing-image resolver for unbounded SVG symbols under style/symbols/.
 *
 * Id conventions accepted:
 *   - `symbols/traffic_signs/DE/foo` → /symbols/traffic_signs/DE/foo.svg
 *   - `symbols/trees/broadleaved` → /symbols/trees/broadleaved.png (also tries .svg)
 * Skips sentinels: '', 'null', 'undefined'.
 *
 * SVGs are rasterized via HTMLImageElement — `createImageBitmap` / `map.loadImage`
 * do not accept SVG (see research/maplibre-ad-hoc-image-loading).
 */
import type { Map as MapLibreMap } from 'maplibre-gl'

const SENTINELS = new Set(['', 'null', 'undefined', 'none'])

function candidateUrls(id: string): string[] {
  const clean = id.replace(/^\/+/, '').replace(/\.svg$/i, '').replace(/\.png$/i, '')
  const pathId = clean.startsWith('symbols/') ? clean : `symbols/${clean}`
  return [`/${pathId}.svg`, `/${pathId}.png`, `/${clean}.svg`, `/${clean}.png`]
}

function loadHtmlImage(url: string, size: number): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const img = new Image()
    img.decoding = 'async'
    img.onload = () => resolve(img)
    img.onerror = () => resolve(null)
    // Explicit size helps SVG without intrinsic dimensions paint into the canvas.
    img.width = size
    img.height = size
    img.src = url
  })
}

async function svgDataUrl(url: string, size: number): Promise<string | null> {
  try {
    const res = await fetch(url)
    if (!res.ok) return null
    let text = await res.text()
    if (!text.includes('<svg')) return null
    // Force a viewport so drawImage has non-zero content.
    if (!/width\s*=/.test(text)) {
      text = text.replace(/<svg\b/, `<svg width="${size}" height="${size}"`)
    }
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(text)}`
  } catch {
    return null
  }
}

async function rasterizeUrl(url: string, size = 64): Promise<ImageData | null> {
  try {
    const isSvg = url.endsWith('.svg')
    const src = isSvg ? await svgDataUrl(url, size) : url
    if (!src) return null
    const img = await loadHtmlImage(src, size)
    if (!img) return null
    const canvas = document.createElement('canvas')
    canvas.width = size
    canvas.height = size
    const ctx = canvas.getContext('2d')
    if (!ctx) return null
    ctx.clearRect(0, 0, size, size)
    ctx.drawImage(img, 0, 0, size, size)
    return ctx.getImageData(0, 0, size, size)
  } catch {
    return null
  }
}

export function installMissingStyleImageResolver(map: MapLibreMap): void {
  map.setMissingStyleImageResolver(async (id) => {
    if (SENTINELS.has(id) || map.hasImage(id)) return

    for (const url of candidateUrls(id)) {
      const image = await rasterizeUrl(url)
      if (!image) continue
      if (map.hasImage(id)) return
      map.addImage(id, image, { pixelRatio: 1 })
      return
    }
  })
}
