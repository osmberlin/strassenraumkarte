/**
 * Pack style/textures/*.png, rasterized pitch SVGs and the closed set of QGIS marker
 * images (`PACKED_ICONS`, style/symbols/**) into MapLibre sprites.
 *
 * MapUnit RasterFill textures are resized so one tile ≈ QGIS ground width at
 * TEXTURE_REF_ZOOM (z18). Pixel-width textures (grass/gravel/sand/forest) stay native.
 * Marker icons keep their aspect ratio at a fixed logical width (`ICON_WIDTH_PX`) with
 * QGIS `param(fill|outline|…)` placeholders replaced by the project's colours.
 * Every ratio is resampled from the source image, never from another ratio's output.
 *
 * Outputs (each as `.png` + `.json`, 1× and `@2x`):
 *   public/sprites/strassenraumkarte          textures / patterns / pitches, palette PNG
 *   public/sprites/strassenraumkarte-symbols  marker icons, RGBA PNG
 *
 * Run: `bun run sprite`
 */
import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'

import sharp from 'sharp'

import {
  ICON_WIDTH_PX,
  PACKED_ICONS,
  iconRasterWidthPx,
  SYMBOL_SPRITE_ID,
  substituteSvgParams,
  type PackedIcon,
} from '../src/style/sprite-icons'

const ROOT = path.resolve(import.meta.dir, '..')
const REPO = path.resolve(ROOT, '..')
const TEXTURES = path.join(REPO, 'style', 'textures')
const PITCHES = path.join(TEXTURES, 'pitches')
const SYMBOLS = path.join(REPO, 'style', 'symbols')
const PAW_SVG = path.join(SYMBOLS, 'leisure', 'paw.svg')
const OUT = path.join(ROOT, 'public', 'sprites')
/** Default sprite: fill textures, patterns, pitches (ids without prefix). */
const TEXTURE_SHEET = 'strassenraumkarte'
/** `symbols` sprite: QGIS marker icons (`symbols:<name>` in the style). */
const SYMBOL_SHEET = 'strassenraumkarte-symbols'

/** Match vector/src/style/metres.ts (Berlin / Neukölln). */
const DEFAULT_LAT = 52.48
const METRES_PER_PIXEL_Z0 = 78271.51696
/** Archive/compare detail zoom — bake MapUnit texture widths here. */
const TEXTURE_REF_ZOOM = 18
const MIN_PATTERN_PX = 16

function pxPerMetre(z: number, lat = DEFAULT_LAT): number {
  return 2 ** z / (METRES_PER_PIXEL_Z0 * Math.cos((lat * Math.PI) / 180))
}

/**
 * QGIS RasterFill MapUnit widths (style/strassenraumkarte.qgz, class="RasterFill").
 * Keys are sprite ids. Pixel-width textures omitted → keep native resolution.
 */
const TEXTURE_WIDTH_M: Record<string, number> = {
  'surface/sett': 11,
  'surface/paving_stones': 4.5,
  'surface/concrete': 3,
  'surface/asphalt': 6,
  wetland: 30,
  water: 35,
  woodchips: 8,
  flowerbed: 10,
}

type SpriteEntry = {
  id: string
  buffer: Buffer
  width: number
  height: number
  /** Sprite JSON pixelRatio when it differs from the sheet ratio (hi-res icons). */
  pixelRatio?: number
}

type SpriteLayout = {
  id: string
  x: number
  y: number
  width: number
  height: number
  pixelRatio: number
}

/**
 * One texture at `pixelRatio`, resampled from the source file. MapUnit textures get the
 * CSS width that matches `widthM` at TEXTURE_REF_ZOOM; pixel-width textures keep the
 * source size as their CSS size.
 */
async function textureEntry(full: string, id: string, pixelRatio: number): Promise<SpriteEntry> {
  const meta = await sharp(full).metadata()
  const srcW = meta.width ?? 0
  const srcH = meta.height ?? 0
  const widthM = TEXTURE_WIDTH_M[id]
  let w1 = srcW
  let h1 = srcH
  if (widthM != null && srcW > 0 && srcH > 0) {
    w1 = Math.max(MIN_PATTERN_PX, Math.round(widthM * pxPerMetre(TEXTURE_REF_ZOOM)))
    h1 = Math.max(1, Math.round((srcH * w1) / srcW))
    if (pixelRatio === 1) {
      console.log(
        `[sprite] ${id} ${srcW}×${srcH} → ${w1}×${h1} (${widthM} m @ z${TEXTURE_REF_ZOOM})`,
      )
    }
  }
  // Pixel-width textures have no detail beyond the source: store them once at source size
  // and declare pixelRatio 1 on every sheet (same CSS size, a quarter of the @2× bytes).
  const native = widthM == null
  const width = native ? srcW : w1 * pixelRatio
  const height = native ? srcH : h1 * pixelRatio
  let img = sharp(full)
  if (width !== srcW || height !== srcH) {
    img = img.resize(width, height, { kernel: 'lanczos3', fit: 'fill' })
  }
  const buffer = await img.ensureAlpha().png().toBuffer()
  return { id, buffer, width, height, ...(native ? { pixelRatio: 1 } : {}) }
}

async function collectPngs(dir: string, prefix: string, pixelRatio: number): Promise<SpriteEntry[]> {
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return []
  }
  const entries: SpriteEntry[] = []
  for (const name of names.sort()) {
    if (!name.endsWith('.png')) continue
    const base = name.replace(/\.png$/i, '')
    const id = prefix ? `${prefix}/${base}` : base
    entries.push(await textureEntry(path.join(dir, name), id, pixelRatio))
  }
  return entries
}

/**
 * One QGIS marker image at `pixelRatio`: ICON_WIDTH_PX logical px wide, height from the
 * source aspect ratio, stored at the resolution it is drawn at (`iconRasterWidthPx`).
 * SVGs are rasterized from the vector source, PNGs are downsampled from the original.
 */
async function iconEntry(icon: PackedIcon, pixelRatio: number): Promise<SpriteEntry> {
  const full = path.join(SYMBOLS, icon.file)
  const width1x = iconRasterWidthPx(icon.groundM)
  const isSvg = icon.file.endsWith('.svg')
  const input: Buffer | string = isSvg
    ? Buffer.from(substituteSvgParams(await readFile(full, 'utf8'), icon.params))
    : full
  const meta = await sharp(input).metadata()
  const srcW = meta.width ?? 0
  const srcH = meta.height ?? 0
  if (srcW <= 0 || srcH <= 0) throw new Error(`[sprite] no intrinsic size: ${icon.file}`)
  // Derive from the 1× size so both sheets describe the same logical box.
  const width = width1x * pixelRatio
  const height = Math.max(1, Math.round((width1x * srcH) / srcW)) * pixelRatio
  const source = isSvg
    ? // Rasterize ≥ 2× the target (and never tiny), then lanczos down: librsvg alone
      // drops thin strokes at 10–20 px and rejects densities that round to a 0 px image.
      sharp(input, {
        density: Math.min(100_000, Math.max(8, (72 * Math.max(width * 2, 256)) / srcW)),
      })
    : sharp(input)
  const buffer = await source
    .resize(width, height, { kernel: 'lanczos3', fit: 'fill' })
    .ensureAlpha()
    .png()
    .toBuffer()
  return {
    id: icon.id.slice(SYMBOL_SPRITE_ID.length + 1),
    buffer,
    width,
    height,
    // Logical width = width / pixelRatio = ICON_WIDTH_PX on every sheet.
    pixelRatio: width / ICON_WIDTH_PX,
  }
}

async function collectPitchSvgs(pixelRatio: number): Promise<SpriteEntry[]> {
  const entries: SpriteEntry[] = []
  let names: string[]
  try {
    names = await readdir(PITCHES)
  } catch {
    return entries
  }
  for (const name of names.sort()) {
    if (!name.endsWith('.svg')) continue
    const full = path.join(PITCHES, name)
    const size = Math.round(64 * pixelRatio)
    const buffer = await sharp(full, { density: 96 * pixelRatio })
      .resize(size, size, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .ensureAlpha()
      .png()
      .toBuffer()
    const meta = await sharp(buffer).metadata()
    entries.push({
      id: `pitches/${name.replace(/\.svg$/i, '')}`,
      buffer,
      width: meta.width ?? size,
      height: meta.height ?? size,
    })
  }
  return entries
}

/**
 * G8 construction LinePatternFill: diagonal orange hatch @ ~67°.
 * QGIS ~1 m stroke / 2.2 m gap → baked at TEXTURE_REF_ZOOM (~5.5 px / ~12 px).
 */
async function buildConstructionHatch(pixelRatio: number): Promise<SpriteEntry> {
  const ppm = pxPerMetre(TEXTURE_REF_ZOOM)
  // ~2.2 m × 3 line slots ≈ 36 px; clamp into the 36–48 px band.
  const size1x = Math.min(48, Math.max(36, Math.round(2.2 * ppm * 3)))
  const size = Math.round(size1x * pixelRatio)
  const stroke = Math.max(1, Math.round(1 * ppm * pixelRatio))
  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
  <g transform="rotate(67 ${size / 2} ${size / 2})" stroke="rgba(255,83,0,0.35)" stroke-width="${stroke}" stroke-linecap="square">
    <line x1="${-size}" y1="${size * 0.15}" x2="${size * 2}" y2="${size * 0.15}"/>
    <line x1="${-size}" y1="${size * 0.5}" x2="${size * 2}" y2="${size * 0.5}"/>
    <line x1="${-size}" y1="${size * 0.85}" x2="${size * 2}" y2="${size * 0.85}"/>
  </g>
</svg>`
  const buffer = await sharp(Buffer.from(svg)).ensureAlpha().png().toBuffer()
  const meta = await sharp(buffer).metadata()
  if (pixelRatio === 1) {
    console.log(
      `[sprite] patterns/construction-hatch ${size}×${size} (1 m stroke / 2.2 m gap @ z${TEXTURE_REF_ZOOM})`,
    )
  }
  return {
    id: 'patterns/construction-hatch',
    buffer,
    width: meta.width ?? size,
    height: meta.height ?? size,
  }
}

/**
 * G1 outdoor_seating LinePatternFill: diagonal `#dce6cb` hatch @ 135°, α 0.67.
 * QGIS 0.5 m stroke / 1.2 m gap → baked at TEXTURE_REF_ZOOM.
 */
async function buildOutdoorSeatingHatch(pixelRatio: number): Promise<SpriteEntry> {
  const ppm = pxPerMetre(TEXTURE_REF_ZOOM)
  const gapM = 1.2
  const strokeM = 0.5
  // 3 line slots spanning the tile so fill-pattern tiles seamlessly.
  const size1x = Math.max(MIN_PATTERN_PX, Math.round(gapM * ppm * 3))
  const size = Math.round(size1x * pixelRatio)
  const stroke = Math.max(1, Math.round(strokeM * ppm * pixelRatio))
  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
  <g transform="rotate(135 ${size / 2} ${size / 2})" stroke="rgba(220,230,203,0.67)" stroke-width="${stroke}" stroke-linecap="square">
    <line x1="${-size}" y1="${size * 0.15}" x2="${size * 2}" y2="${size * 0.15}"/>
    <line x1="${-size}" y1="${size * 0.5}" x2="${size * 2}" y2="${size * 0.5}"/>
    <line x1="${-size}" y1="${size * 0.85}" x2="${size * 2}" y2="${size * 0.85}"/>
  </g>
</svg>`
  const buffer = await sharp(Buffer.from(svg)).ensureAlpha().png().toBuffer()
  const meta = await sharp(buffer).metadata()
  if (pixelRatio === 1) {
    console.log(
      `[sprite] patterns/outdoor-seating-hatch ${size}×${size} (${strokeM} m stroke / ${gapM} m gap @ z${TEXTURE_REF_ZOOM})`,
    )
  }
  return {
    id: 'patterns/outdoor-seating-hatch',
    buffer,
    width: meta.width ?? size,
    height: meta.height ?? size,
  }
}

/**
 * G8 dog-park PointPatternFill: transparent tile with centred paw.
 * QGIS ~10 m grid → tile ≈ 55 px @ z18; paw ~20 px. Displacement dropped.
 */
async function buildDogParkPaw(pixelRatio: number): Promise<SpriteEntry> {
  const ppm = pxPerMetre(TEXTURE_REF_ZOOM)
  const tile1x = Math.round(10 * ppm)
  const paw1x = Math.round(20)
  const tile = Math.round(tile1x * pixelRatio)
  const pawSize = Math.round(paw1x * pixelRatio)
  const paw = await sharp(PAW_SVG, { density: 96 * pixelRatio })
    .resize(pawSize, pawSize, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .ensureAlpha()
    .png()
    .toBuffer()
  const left = Math.round((tile - pawSize) / 2)
  const top = Math.round((tile - pawSize) / 2)
  const buffer = await sharp({
    create: {
      width: tile,
      height: tile,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: paw, left, top }])
    .png()
    .toBuffer()
  if (pixelRatio === 1) {
    console.log(
      `[sprite] patterns/dog-park-paw ${tile}×${tile} (paw ${pawSize}px, 10 m grid @ z${TEXTURE_REF_ZOOM})`,
    )
  }
  return {
    id: 'patterns/dog-park-paw',
    buffer,
    width: tile,
    height: tile,
  }
}

/** Simple shelf packer (row-based). */
function pack(entries: SpriteEntry[], pixelRatio: number): {
  width: number
  height: number
  layout: SpriteLayout[]
} {
  // Id tie-break keeps the layout independent of readdir order.
  const sorted = [...entries].sort(
    (a, b) => b.height - a.height || b.width - a.width || (a.id < b.id ? -1 : 1),
  )
  const maxRowWidth = 1024 * pixelRatio
  let x = 0
  let y = 0
  let rowH = 0
  let sheetW = 0
  const layout: SpriteLayout[] = []

  for (const e of sorted) {
    if (x > 0 && x + e.width > maxRowWidth) {
      x = 0
      y += rowH
      rowH = 0
    }
    layout.push({
      id: e.id,
      x,
      y,
      width: e.width,
      height: e.height,
      pixelRatio: e.pixelRatio ?? pixelRatio,
    })
    sheetW = Math.max(sheetW, x + e.width)
    rowH = Math.max(rowH, e.height)
    x += e.width
  }

  return {
    width: Math.max(1, sheetW),
    height: Math.max(1, y + rowH),
    layout,
  }
}

/**
 * Sheet encodings.
 * - `palette`: one 256-colour palette (libimagequant via sharp, dithered) for the texture
 *   sheet. It is ~4× smaller than RGBA and the content is photographic noise drawn at low
 *   opacity, where the dithered error (RMSE ≈ 4/255) is not visible. Output is byte-stable
 *   for a given sharp/libvips version.
 * - `rgba`: lossless for the marker sheet — flat brand colours, gradients and soft alpha
 *   edges shift visibly when they have to share one palette, and the sheet is small anyway.
 */
type SheetEncoding = 'rgba' | 'palette'

async function writeSprite(
  entries: SpriteEntry[],
  pixelRatio: number,
  basename: string,
  encoding: SheetEncoding,
) {
  const { width, height, layout } = pack(entries, pixelRatio)
  const composites = layout.map((l) => {
    const src = entries.find((e) => e.id === l.id)!
    return { input: src.buffer, left: l.x, top: l.y }
  })

  const suffix = pixelRatio === 2 ? '@2x' : ''
  const pngPath = path.join(OUT, `${basename}${suffix}.png`)
  const jsonPath = path.join(OUT, `${basename}${suffix}.json`)

  // Composite to raw first: sharp applies png() options to the composited result only
  // when it is the final step of the same pipeline, and raw keeps the two steps explicit.
  const raw = await sharp({
    create: {
      width,
      height,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite(composites)
    .raw()
    .toBuffer()
  const sheet = sharp(raw, { raw: { width, height, channels: 4 } })
  await (encoding === 'palette'
    ? sheet.png({ palette: true, colours: 256, quality: 100, dither: 1, effort: 10, compressionLevel: 9 })
    : sheet.png({ compressionLevel: 9, adaptiveFiltering: true })
  ).toFile(pngPath)

  const json: Record<string, { x: number; y: number; width: number; height: number; pixelRatio: number }> =
    {}
  for (const l of layout) {
    json[l.id] = {
      x: l.x,
      y: l.y,
      width: l.width,
      height: l.height,
      pixelRatio: l.pixelRatio,
    }
  }
  await writeFile(jsonPath, JSON.stringify(json, null, 2))
  const { size } = await stat(pngPath)
  console.log(
    `[sprite] ${path.basename(pngPath)} ${width}×${height}, ${layout.length} images, ${encoding}, ${(size / 1024).toFixed(0)} KiB`,
  )
}

async function main() {
  await mkdir(OUT, { recursive: true })

  for (const ratio of [1, 2] as const) {
    const textures = [
      ...(await collectPngs(TEXTURES, '', ratio)),
      ...(await collectPngs(path.join(TEXTURES, 'surface'), 'surface', ratio)),
    ]
    const pitches = await collectPitchSvgs(ratio)
    const patterns = await Promise.all([
      buildConstructionHatch(ratio),
      buildOutdoorSeatingHatch(ratio),
      buildDogParkPaw(ratio),
    ])
    const icons = await Promise.all(PACKED_ICONS.map((icon) => iconEntry(icon, ratio)))
    await writeSprite([...textures, ...pitches, ...patterns], ratio, TEXTURE_SHEET, 'palette')
    await writeSprite(icons, ratio, SYMBOL_SHEET, 'rgba')
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
