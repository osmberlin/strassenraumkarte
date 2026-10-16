/**
 * Convert lon/lat/zoom → Web Mercator XYZ tile id (z/x/y).
 *
 * Usage:
 *   bun run scripts/lonlat-to-tile.ts --lon 13.4222 --lat 52.4768 --zoom 17
 *   bun run scripts/lonlat-to-tile.ts --lon 13.4222 --lat 52.4768 --zooms 15,16,17,18
 *   bun run scripts/lonlat-to-tile.ts --from-locations   # vector/locations.ts COMPARE_LOCATIONS
 */
import path from 'node:path'

export type TileId = { z: number; x: number; y: number; id: string }

/** Web Mercator XYZ (EPSG:3857 slippy map) — same convention as render/xyz_tiles.py. */
export function lonLatToTile(lon: number, lat: number, zoom: number): TileId {
  if (!Number.isInteger(zoom) || zoom < 0 || zoom > 30) {
    throw new Error(`zoom must be integer 0–30, got ${zoom}`)
  }
  if (lon < -180 || lon > 180) throw new Error(`lon out of range: ${lon}`)
  if (lat <= -85.05112878 || lat >= 85.05112878) {
    throw new Error(`lat out of Web Mercator range: ${lat}`)
  }
  const n = 2 ** zoom
  const x = Math.floor(((lon + 180) / 360) * n)
  const latRad = (lat * Math.PI) / 180
  const y = Math.floor(
    ((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * n,
  )
  return { z: zoom, x, y, id: `${zoom}/${x}/${y}` }
}

type Args = {
  lon?: number
  lat?: number
  zoom?: number
  zooms?: number[]
  fromLocations: boolean
  json: boolean
}

function parseArgs(argv: string[]): Args {
  const out: Args = { fromLocations: false, json: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => {
      const v = argv[++i]
      if (v === undefined) throw new Error(`missing value for ${a}`)
      return v
    }
    if (a === '--lon') out.lon = Number(next())
    else if (a === '--lat') out.lat = Number(next())
    else if (a === '--zoom' || a === '-z') out.zoom = Number(next())
    else if (a === '--zooms') {
      out.zooms = next()
        .split(',')
        .map((s) => Number(s.trim()))
        .filter((n) => !Number.isNaN(n))
    } else if (a === '--from-locations') out.fromLocations = true
    else if (a === '--json') out.json = true
    else if (a === '--help' || a === '-h') {
      console.log(`Usage:
  bun run scripts/lonlat-to-tile.ts --lon LON --lat LAT --zoom Z
  bun run scripts/lonlat-to-tile.ts --lon LON --lat LAT --zooms 15,16,17,18
  bun run scripts/lonlat-to-tile.ts --from-locations [--zooms 15,16,17,18] [--json]`)
      process.exit(0)
    } else throw new Error(`unknown arg: ${a}`)
  }
  return out
}

async function main() {
  const args = parseArgs(process.argv.slice(2))

  if (args.fromLocations) {
    const locPath = path.resolve(import.meta.dir, '../../../vector/locations.ts')
    const mod = await import(locPath)
    const locations = mod.COMPARE_LOCATIONS as Array<{
      id: string
      label: string
      longitude: number
      latitude: number
      zoom: number
    }>
    const zooms = args.zooms
    const rows = locations.flatMap((loc) => {
      const zs = zooms ?? [loc.zoom]
      return zs.map((z) => {
        const t = lonLatToTile(loc.longitude, loc.latitude, z)
        return { location: loc.id, label: loc.label, ...t }
      })
    })
    if (args.json) console.log(JSON.stringify(rows, null, 2))
    else {
      for (const r of rows) {
        console.log(`${r.location}\t${r.id}\tz=${r.z}\tx=${r.x}\ty=${r.y}\t${r.label}`)
      }
    }
    return
  }

  if (args.lon === undefined || args.lat === undefined) {
    throw new Error('need --lon/--lat or --from-locations')
  }
  const zooms = args.zooms ?? (args.zoom !== undefined ? [args.zoom] : null)
  if (!zooms) throw new Error('need --zoom or --zooms')

  const tiles = zooms.map((z) => lonLatToTile(args.lon!, args.lat!, z))
  if (args.json) console.log(JSON.stringify(tiles, null, 2))
  else {
    for (const t of tiles) console.log(t.id)
  }
}

if (import.meta.main) {
  main().catch((err) => {
    console.error(err)
    process.exit(1)
  })
}
