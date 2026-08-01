/**
 * Pack style/textures/*.png (+ rasterized pitch SVGs) into MapLibre sprites.
 *
 * MapUnit RasterFill textures are resized so one tile ≈ QGIS ground width at
 * TEXTURE_REF_ZOOM (z18). Pixel-width textures (grass/gravel/sand/forest) stay native.
 *
 * Outputs:
 *   public/sprites/strassenraumkarte.png + .json
 *   public/sprites/strassenraumkarte@2x.png + .json
 *
 * Run: `bun run sprite`
 */
import { mkdir, readdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

import sharp from 'sharp'

const ROOT = path.resolve(import.meta.dir, '..')
const REPO = path.resolve(ROOT, '..')
const TEXTURES = path.join(REPO, 'style', 'textures')
const PITCHES = path.join(TEXTURES, 'pitches')
const PAW_SVG = path.join(REPO, 'style', 'symbols', 'leisure', 'paw.svg')
const OUT = path.join(ROOT, 'public', 'sprites')

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
}

type SpriteLayout = {
  id: string
  x: number
  y: number
  width: number
  height: number
  pixelRatio: number
}

/** Resize a MapUnit texture so its CSS width matches `widthM` at TEXTURE_REF_ZOOM. */
async function rescaleMapUnitTexture(
  id: string,
  buffer: Buffer,
  srcW: number,
  srcH: number,
  widthM: number,
): Promise<SpriteEntry> {
  const ppm = pxPerMetre(TEXTURE_REF_ZOOM)
  const targetW = Math.max(MIN_PATTERN_PX, Math.round(widthM * ppm))
  const targetH = Math.max(1, Math.round((srcH * targetW) / srcW))
  if (targetW === srcW && targetH === srcH) {
    return { id, buffer, width: srcW, height: srcH }
  }
  const out = await sharp(buffer)
    .resize(targetW, targetH, { kernel: 'lanczos3', fit: 'fill' })
    .ensureAlpha()
    .png()
    .toBuffer()
  console.log(
    `[sprite] ${id} ${srcW}×${srcH} → ${targetW}×${targetH} (${widthM} m @ z${TEXTURE_REF_ZOOM})`,
  )
  return { id, buffer: out, width: targetW, height: targetH }
}

async function collectPngs(dir: string, prefix = ''): Promise<SpriteEntry[]> {
  const entries: SpriteEntry[] = []
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return entries
  }
  for (const name of names) {
    const full = path.join(dir, name)
    if (name.endsWith('.png')) {
      const id = (prefix ? `${prefix}/${name.replace(/\.png$/i, '')}` : name.replace(/\.png$/i, ''))
        .replaceAll('\\', '/')
      const meta = await sharp(full).metadata()
      const srcW = meta.width ?? 0
      const srcH = meta.height ?? 0
      const buffer = await sharp(full).ensureAlpha().png().toBuffer()
      const widthM = TEXTURE_WIDTH_M[id]
      if (widthM != null && srcW > 0 && srcH > 0) {
        entries.push(await rescaleMapUnitTexture(id, buffer, srcW, srcH, widthM))
      } else {
        entries.push({ id, buffer, width: srcW, height: srcH })
      }
    }
  }
  return entries
}

async function collectPitchSvgs(pixelRatio: number): Promise<SpriteEntry[]> {
  const entries: SpriteEntry[] = []
  let names: string[]
  try {
    names = await readdir(PITCHES)
  } catch {
    return entries
  }
  for (const name of names) {
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
  const sorted = [...entries].sort((a, b) => b.height - a.height || b.width - a.width)
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
      pixelRatio,
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

async function writeSprite(entries: SpriteEntry[], pixelRatio: number, suffix: string) {
  const { width, height, layout } = pack(entries, pixelRatio)
  const composites = layout.map((l) => {
    const src = entries.find((e) => e.id === l.id)!
    return { input: src.buffer, left: l.x, top: l.y }
  })

  const pngPath = path.join(OUT, `strassenraumkarte${suffix}.png`)
  const jsonPath = path.join(OUT, `strassenraumkarte${suffix}.json`)

  await sharp({
    create: {
      width,
      height,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite(composites)
    .png()
    .toFile(pngPath)

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
  console.log(`[sprite] ${path.basename(pngPath)} ${width}×${height}, ${layout.length} icons`)
}

async function main() {
  await mkdir(OUT, { recursive: true })

  // Collect once at 1× (MapUnit textures already ground-scaled @ z18).
  const rootPngs = await collectPngs(TEXTURES)
  const surfacePngs = await collectPngs(path.join(TEXTURES, 'surface'), 'surface')
  const textures1x = [...rootPngs, ...surfacePngs]

  for (const ratio of [1, 2] as const) {
    const suffix = ratio === 2 ? '@2x' : ''
    const pitches = await collectPitchSvgs(ratio)
    const patterns = await Promise.all([
      buildConstructionHatch(ratio),
      buildOutdoorSeatingHatch(ratio),
      buildDogParkPaw(ratio),
    ])
    // @2×: scale the already ground-scaled 1× buffers.
    const textures =
      ratio === 1
        ? textures1x
        : await Promise.all(
            textures1x.map(async (e) => {
              const buffer = await sharp(e.buffer)
                .resize(e.width * 2, e.height * 2, { kernel: 'lanczos3' })
                .png()
                .toBuffer()
              return { ...e, buffer, width: e.width * 2, height: e.height * 2 }
            }),
          )
    await writeSprite([...textures, ...pitches, ...patterns], ratio, suffix)
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
