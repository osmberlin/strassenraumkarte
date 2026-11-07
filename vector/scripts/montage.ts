/**
 * Stitch per-location screenshots from several runs into one row per location.
 *
 * Usage: `bun run scripts/montage.ts <out-dir> <label=dir/suffix>...`
 * e.g.   `bun run scripts/montage.ts compare-output/montage qgis=before/raster before=before/vector after=after/vector`
 * (dirs are relative to compare-output/; output is JPEG so the montages can be
 * committed under docs/maplibre-progress/ without bloating the repo)
 */
import { existsSync } from 'node:fs'
import { mkdir } from 'node:fs/promises'
import path from 'node:path'

import sharp, { type OverlayOptions } from 'sharp'

import { COMPARE_LOCATIONS } from '../locations'

const ROOT = path.resolve(import.meta.dir, '..', 'compare-output')
const [outArg, ...columnArgs] = process.argv.slice(2)
if (!outArg || columnArgs.length === 0) {
  console.error('usage: montage.ts <out-dir> <label=dir/suffix>...')
  process.exit(1)
}
const outDir = path.resolve(outArg)
const columns = columnArgs.map((arg) => {
  const [label, spec] = arg.split('=') as [string, string]
  const [dir, suffix] = spec.split('/') as [string, string]
  return { label, dir, suffix }
})

const LABEL_H = 28

await mkdir(outDir, { recursive: true })
for (const loc of COMPARE_LOCATIONS) {
  // Locations added later have no screenshot in older runs — skip instead of failing.
  const missing = columns.find(
    (c) => !existsSync(path.join(ROOT, c.dir, `${loc.id}-${c.suffix}.png`)),
  )
  if (missing) {
    console.log(`[montage] skip ${loc.id} (no ${missing.dir}/${loc.id}-${missing.suffix}.png)`)
    continue
  }
  const tiles = await Promise.all(
    columns.map(async (c) => {
      const img = sharp(path.join(ROOT, c.dir, `${loc.id}-${c.suffix}.png`))
      const { width = 0, height = 0 } = await img.metadata()
      return { ...c, buf: await img.toBuffer(), width, height }
    }),
  )
  const height = Math.max(...tiles.map((t) => t.height)) + LABEL_H
  let x = 0
  const composite: OverlayOptions[] = []
  for (const t of tiles) {
    const label = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${t.width}" height="${LABEL_H}"><rect width="100%" height="100%" fill="#111"/><text x="8" y="19" font-family="sans-serif" font-size="15" fill="#eee">${t.label} · ${loc.label}</text></svg>`,
    )
    composite.push({ input: label, left: x, top: 0 }, { input: t.buf, left: x, top: LABEL_H })
    x += t.width + 4
  }
  const file = path.join(outDir, `${loc.id}.jpg`)
  await sharp({ create: { width: x - 4, height, channels: 3, background: '#111' } })
    .composite(composite)
    .jpeg({ quality: 86, mozjpeg: true })
    .toFile(file)
  console.log(`[montage] ${file}`)
}
