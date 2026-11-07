/**
 * tippecanoe per layer group + tile-join → public/tiles/strassenraumkarte.pmtiles
 */

import { mkdir, rm, stat } from 'node:fs/promises'
import path from 'node:path'

import { LAYERS, TILE_GROUPS, type LayerDef, type TileGroup } from '../layers'

const ROOT = path.resolve(import.meta.dir, '..')
const OUT_DIR = path.join(ROOT, 'out')
const TMP_DIR = path.join(OUT_DIR, '_tiles')
const PUBLIC_TILES = path.join(ROOT, 'public', 'tiles')
const FINAL = path.join(PUBLIC_TILES, 'strassenraumkarte.pmtiles')

const TIPPECANOE_COMMON = [
  '-r1',
  '--no-tiny-polygon-reduction',
  '--simplification=2',
  '--preserve-input-order',
  '--no-tile-compression', // easier debugging; re-enable later if size bites
  '-f',
] as const

async function run(cmd: string[], label: string): Promise<void> {
  console.log(`[tiles] ${label}: ${cmd.join(' ')}`)
  const proc = Bun.spawn(cmd, { stdout: 'inherit', stderr: 'inherit', env: process.env })
  const code = await proc.exited
  if (code !== 0) throw new Error(`${label} failed (exit ${code})`)
}

function groupLayers(group: TileGroup): LayerDef[] {
  return LAYERS.filter((l) => l.group === group)
}

function groupZoom(layers: LayerDef[]): { minzoom: number; maxzoom: number } {
  return {
    minzoom: Math.min(...layers.map((l) => l.minzoom)),
    maxzoom: Math.max(...layers.map((l) => l.maxzoom)),
  }
}

/**
 * tippecanoe omits source-layers with zero features, which makes MapLibre
 * console.error when the style still references them. Seed an empty export
 * with one tiny stub inside the starter extract so the layer stays in metadata
 * without expanding PMTiles bounds.
 */
async function ensureLayerHasFeatures(layer: LayerDef, geo: string): Promise<void> {
  const text = (await Bun.file(geo).text()).trim()
  if (text !== '') return

  // SW corner of the Neukölln starter bbox (~10 m box — tippecanoe drops sub-metre stubs).
  const lon = 13.3861
  const lat = 52.4657
  const d = 0.00012

  const stub =
    layer.paint === 'fill'
      ? {
          type: 'Feature',
          properties: { _empty_stub: 1 },
          geometry: {
            type: 'Polygon',
            coordinates: [
              [
                [lon, lat],
                [lon + d, lat],
                [lon + d, lat + d],
                [lon, lat + d],
                [lon, lat],
              ],
            ],
          },
        }
      : layer.paint === 'line'
        ? {
            type: 'Feature',
            properties: { _empty_stub: 1 },
            geometry: {
              type: 'LineString',
              coordinates: [
                [lon, lat],
                [lon + d, lat],
              ],
            },
          }
        : {
            type: 'Feature',
            properties: { _empty_stub: 1 },
            geometry: { type: 'Point', coordinates: [lon, lat] },
          }

  await Bun.write(geo, `${JSON.stringify(stub)}\n`)
  console.log(`[tiles] ${layer.id}: empty export — seeded tippecanoe stub`)
}

async function buildGroup(group: TileGroup): Promise<string | null> {
  const layers = groupLayers(group)
  if (layers.length === 0) return null

  for (const layer of layers) {
    const geo = path.join(OUT_DIR, `${layer.id}.geojsonl`)
    if (!(await Bun.file(geo).exists())) {
      throw new Error(`Missing export ${geo} — run: bun run export`)
    }
    await ensureLayerHasFeatures(layer, geo)
  }

  const { minzoom, maxzoom } = groupZoom(layers)
  const out = path.join(TMP_DIR, `${group}.pmtiles`)

  // One tippecanoe invocation with named layers (-Lname:file)
  const layerArgs = layers.flatMap((l) => [
    `-L${l.id}:${path.join(OUT_DIR, `${l.id}.geojsonl`)}`,
  ])

  await run(
    [
      'tippecanoe',
      ...TIPPECANOE_COMMON,
      '-Z',
      String(minzoom),
      '-z',
      String(maxzoom),
      '-o',
      out,
      ...layerArgs,
    ],
    `tippecanoe:${group}`,
  )

  const info = await stat(out)
  console.log(`[tiles] ${group}: ${(info.size / 1024 / 1024).toFixed(2)} MiB (z${minzoom}–${maxzoom})`)
  return out
}

async function main() {
  await mkdir(TMP_DIR, { recursive: true })
  await mkdir(PUBLIC_TILES, { recursive: true })

  const parts: string[] = []
  for (const group of TILE_GROUPS) {
    const part = await buildGroup(group)
    if (part) parts.push(part)
  }

  if (parts.length === 0) throw new Error('No tile groups produced')

  await rm(FINAL, { force: true })
  await run(['tile-join', '-f', '-o', FINAL, ...parts], 'tile-join')

  const info = await stat(FINAL)
  console.log(`[tiles] wrote ${FINAL} (${(info.size / 1024 / 1024).toFixed(2)} MiB)`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
