/**
 * Pack style/textures/*.png (+ rasterized pitch SVGs) into MapLibre sprites.
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
      const id = prefix ? `${prefix}/${name.replace(/\.png$/i, '')}` : name.replace(/\.png$/i, '')
      const meta = await sharp(full).metadata()
      const buffer = await sharp(full).ensureAlpha().png().toBuffer()
      entries.push({
        id: id.replaceAll('\\', '/'),
        buffer,
        width: meta.width ?? 0,
        height: meta.height ?? 0,
      })
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
 * G8 construction LinePatternFill stand-in: diagonal orange hatch @ ~67°.
 * Tile size chosen so fill-pattern reads as medium-density stripes (not ground-metre exact).
 */
async function buildConstructionHatch(pixelRatio: number): Promise<SpriteEntry> {
  const size = Math.round(64 * pixelRatio)
  // Stripe width ≈ 1/5 of tile, spacing ≈ tile (QGIS: 1 m line / 2.2 m gap at fixed pixel scale).
  const stroke = Math.max(2, Math.round(8 * pixelRatio))
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
  return {
    id: 'patterns/construction-hatch',
    buffer,
    width: meta.width ?? size,
    height: meta.height ?? size,
  }
}

/**
 * G8 dog-park PointPatternFill stand-in: transparent tile with centred paw.
 * Displacement / 10 m grid dropped (G0.4 fixed sprite pixel scale).
 */
async function buildDogParkPaw(pixelRatio: number): Promise<SpriteEntry> {
  const tile = Math.round(96 * pixelRatio)
  const pawSize = Math.round(36 * pixelRatio)
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

  const rootPngs = await collectPngs(TEXTURES)
  const surfacePngs = await collectPngs(path.join(TEXTURES, 'surface'), 'surface')

  for (const ratio of [1, 2] as const) {
    const suffix = ratio === 2 ? '@2x' : ''
    const pitches = await collectPitchSvgs(ratio)
    const patterns = await Promise.all([
      buildConstructionHatch(ratio),
      buildDogParkPaw(ratio),
    ])
    // Scale 1x textures for @2x by resizing
    const textures =
      ratio === 1
        ? [...rootPngs, ...surfacePngs]
        : await Promise.all(
            [...rootPngs, ...surfacePngs].map(async (e) => {
              const buffer = await sharp(e.buffer)
                .resize(e.width * 2, e.height * 2, { kernel: 'nearest' })
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
