/**
 * MapLibre v6 missing-image resolver for the open-ended traffic sign catalogue under
 * `style/symbols/traffic_signs/` (road_marking_node `"class"/"symbol"` → any file).
 * Everything with a fixed id lives in the `symbols:` sprite (`src/style/sprite-icons.ts`).
 *
 * Id: `symbols/traffic_signs/<class>/<symbol>[#<stretch>]` → `/symbols/traffic_signs/<class>/<symbol>.svg`
 *   `#<stretch>` (optional) = wanted height/width ratio. QGIS sets marker width and height
 *   independently for painted signs; MapLibre can only scale an icon uniformly, so the
 *   stretch is baked into the raster.
 *
 * Same sizing contract as the sprite: `ICON_WIDTH_PX` logical px wide, height from the
 * aspect ratio, rasterized at drawn size × devicePixelRatio (`iconRasterWidthPx`). QGIS `param(fill) …` placeholders are
 * replaced first (browsers treat them as invalid paint → black).
 *
 * SVGs are rasterized via HTMLImageElement — `createImageBitmap` / `map.loadImage`
 * do not accept SVG (see research/maplibre-ad-hoc-image-loading).
 *
 * Install the resolver *before* mounting symbol layers (gate layers on map `load`),
 * otherwise ImageManager may request icons while `missingImageResolver` is still null.
 */
import type { Map as MapLibreMap } from 'maplibre-gl'

import {
  ICON_WIDTH_PX,
  RUNTIME_SIGN_GROUND_M,
  iconRasterWidthPx,
  substituteSvgParams,
} from '../style/sprite-icons'

const RUNTIME_PREFIX = 'symbols/traffic_signs/'
const INSTALLED = new WeakSet<MapLibreMap>()
/** Cap raster size for extreme stretch values from data. */
const MAX_STRETCH = 8

type ParsedId = { url: string; stretch: number | null }

function parseId(id: string): ParsedId | null {
  if (!id.startsWith(RUNTIME_PREFIX)) return null
  const hash = id.lastIndexOf('#')
  const pathId = hash >= 0 ? id.slice(0, hash) : id
  // `<class>/<symbol>` from tile data — keep it inside the sign folder.
  if (pathId.includes('..') || pathId.endsWith('/') || /\/(null|undefined)?$/.test(pathId)) {
    return null
  }
  const stretch = hash >= 0 ? Number(id.slice(hash + 1)) : Number.NaN
  return {
    url: `/${pathId.split('/').map(encodeURIComponent).join('/')}.svg`,
    stretch: Number.isFinite(stretch) && stretch > 0 ? Math.min(stretch, MAX_STRETCH) : null,
  }
}

function loadHtmlImage(src: string): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const img = new Image()
    img.decoding = 'async'
    img.onload = () => resolve(img)
    img.onerror = () => resolve(null)
    img.src = src
  })
}

/** Height/width from the root `<svg>` (`width`/`height`, else `viewBox`). */
function svgAspect(svg: string): number | null {
  const root = /<svg\b[^>]*>/i.exec(svg)?.[0]
  if (!root) return null
  const num = (name: string) => {
    const m = new RegExp(`\\s${name}\\s*=\\s*["']\\s*([0-9.]+)(px)?\\s*["']`, 'i').exec(root)
    return m ? Number(m[1]) : Number.NaN
  }
  let w = num('width')
  let h = num('height')
  if (!(w > 0 && h > 0)) {
    const vb = /\sviewBox\s*=\s*["']([^"']+)["']/i.exec(root)?.[1]?.trim().split(/[\s,]+/).map(Number)
    w = vb?.[2] ?? Number.NaN
    h = vb?.[3] ?? Number.NaN
  }
  return w > 0 && h > 0 ? h / w : null
}

/** Raster at `width` px; the caller declares `pixelRatio = width / ICON_WIDTH_PX`. */
async function rasterize({ url, stretch }: ParsedId, width: number): Promise<ImageData | null> {
  try {
    const res = await fetch(url)
    if (!res.ok) return null
    const text = await res.text()
    if (!text.includes('<svg')) return null
    const svg = substituteSvgParams(text)
    const img = await loadHtmlImage(`data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`)
    if (!img) return null
    const natural = img.naturalWidth > 0 ? img.naturalHeight / img.naturalWidth : 1
    const aspect = stretch ?? svgAspect(svg) ?? natural
    const height = Math.max(1, Math.round(width * aspect))
    const canvas = document.createElement('canvas')
    canvas.width = width
    canvas.height = height
    const ctx = canvas.getContext('2d')
    if (!ctx) return null
    // drawImage re-rasterizes the SVG at the destination size (crisp, stretch included).
    ctx.drawImage(img, 0, 0, width, height)
    return ctx.getImageData(0, 0, width, height)
  } catch {
    return null
  }
}

export function installMissingStyleImageResolver(map: MapLibreMap): void {
  if (INSTALLED.has(map)) return
  INSTALLED.add(map)

  map.setMissingStyleImageResolver(async (id) => {
    const parsed = parseId(id)
    if (!parsed || map.hasImage(id)) return

    // Same resolution rule as the sprite (no mipmaps → store at drawn size), × screen density.
    const dpr = Math.min(4, Math.max(1, Math.ceil(window.devicePixelRatio || 1)))
    const width = iconRasterWidthPx(RUNTIME_SIGN_GROUND_M) * dpr
    const image = await rasterize(parsed, width)
    if (!image || map.hasImage(id)) return
    try {
      map.addImage(id, image, { pixelRatio: width / ICON_WIDTH_PX })
    } catch {
      // Parallel requests for the same id can race past hasImage().
    }
  })
}
