/**
 * PostGIS → GeoJSONSeq (EPSG:4326) via ogr2ogr.
 *
 * Connection defaults match data/db_config.sh (DB_* env vars).
 * Password: PGPASSWORD, or omit to use ~/.pgpass.
 */

import { mkdir, rm, stat } from 'node:fs/promises'
import path from 'node:path'

import { LAYERS, type LayerDef } from '../layers'

const ROOT = path.resolve(import.meta.dir, '..')
const OUT_DIR = path.join(ROOT, 'out')

function pgConn(): string {
  const host = process.env.DB_HOST ?? 'localhost'
  const port = process.env.DB_PORT ?? '5433'
  const dbname = process.env.DB_NAME ?? 'strassenraumkarte'
  const user = process.env.DB_USER ?? 'postgres'
  const password = process.env.PGPASSWORD ?? process.env.DB_PASSWORD
  const parts = [`host=${host}`, `port=${port}`, `dbname=${dbname}`, `user=${user}`]
  if (password) parts.push(`password=${password}`)
  return `PG:${parts.join(' ')}`
}

/** Project data is EPSG:3857; some tables lack SRID metadata. */
function geomSql(): string {
  return 'ST_Transform(ST_SetSRID(geom, 3857), 4326) AS geom'
}

function selectSql(layer: LayerDef): string {
  const cols = [...layer.columns, geomSql()]
  const where = layer.filter ? ` WHERE ${layer.filter}` : ''
  return `SELECT ${cols.join(', ')} FROM ${layer.table}${where}`
}

async function exportLayer(layer: LayerDef, conn: string): Promise<void> {
  const outFile = path.join(OUT_DIR, `${layer.id}.geojsonl`)
  await rm(outFile, { force: true })

  const args = [
    '-f',
    'GeoJSONSeq',
    outFile,
    conn,
    '-sql',
    selectSql(layer),
    '-nln',
    layer.id,
    '-lco',
    'COORDINATE_PRECISION=7',
  ]

  console.log(`[export] ${layer.id} ← ${layer.table}`)
  const proc = Bun.spawn(['ogr2ogr', ...args], {
    stdout: 'inherit',
    stderr: 'inherit',
    env: process.env,
  })
  const code = await proc.exited
  if (code !== 0) {
    throw new Error(`ogr2ogr failed for ${layer.id} (exit ${code})`)
  }

  const info = await stat(outFile)
  const text = await Bun.file(outFile).text()
  const features = text.trim() === '' ? 0 : text.trimEnd().split('\n').length
  console.log(
    `[export] ${layer.id}: ${features} features, ${(info.size / 1024 / 1024).toFixed(2)} MiB`,
  )
}

async function main() {
  const only = process.argv.slice(2).filter((a) => !a.startsWith('-'))
  const layers = only.length
    ? LAYERS.filter((l) => only.includes(l.id) || only.includes(l.table))
    : LAYERS

  if (layers.length === 0) {
    throw new Error(`No layers matched: ${only.join(', ')}`)
  }

  await mkdir(OUT_DIR, { recursive: true })
  const conn = pgConn()
  console.log(`[export] ${layers.length} layer(s) → ${OUT_DIR}`)

  for (const layer of layers) {
    await exportLayer(layer, conn)
  }

  console.log('[export] done')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
