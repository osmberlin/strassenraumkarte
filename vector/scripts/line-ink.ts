/**
 * Measure how much "ink" thin building lines put down in a screenshot run, for the QGIS
 * pane and the vector pane: projects `out/building_lines.geojsonl` into the screenshot,
 * integrates the darkening across each line where both sides are flat roof, and reports
 * it in pixels of full line colour. Used to calibrate the sub-pixel line patch
 * (docs/maplibre-patches.md).
 *
 * Usage: `bun run scripts/line-ink.ts <run> <location-id>...` after
 *        `SHOT_OUT=compare-output/<run> bun run screenshots`.
 */
import sharp from 'sharp'
import { readFileSync } from 'node:fs'
import { COMPARE_LOCATIONS } from '../locations'
const lines = readFileSync(new URL('../out/building_lines.geojsonl', import.meta.url), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
const mx = (lon: number) => (lon + 180) / 360
const my = (lat: number) => { const s = Math.sin((lat * Math.PI) / 180); return 0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI) }
const [run, ...locs] = process.argv.slice(2)
for (const id of locs) for (const kind of ['raster', 'vector']) {
  const loc = COMPARE_LOCATIONS.find((l) => l.id === id)!
  const { data, info } = await sharp(`${import.meta.dir}/../compare-output/${run}/${id}-${kind}.png`).raw().toBuffer({ resolveWithObject: true })
  const W = info.width, H = info.height, C = info.channels, S = 512 * 2 ** loc.zoom
  const G = (x: number, y: number) => { // bilinear G
    const x0 = Math.floor(x), y0 = Math.floor(y), fx = x - x0, fy = y - y0
    const g = (i: number, j: number) => data[(j * W + i) * C + 1]!
    return g(x0, y0) * (1 - fx) * (1 - fy) + g(x0 + 1, y0) * fx * (1 - fy) + g(x0, y0 + 1) * (1 - fx) * fy + g(x0 + 1, y0 + 1) * fx * fy
  }
  const R = (x: number, y: number) => data[(Math.round(y) * W + Math.round(x)) * C]!
  const stats: Record<string, number[]> = {}
  for (const f of lines) {
    const cls = f.properties.class
    const rings = f.geometry.type === 'LineString' ? [f.geometry.coordinates] : f.geometry.coordinates
    for (const ring of rings) for (let i = 0; i + 1 < ring.length; i++) {
      const a = [(mx(ring[i][0]) - mx(loc.longitude)) * S + W / 2, (my(ring[i][1]) - my(loc.latitude)) * S + H / 2]
      const b = [(mx(ring[i + 1][0]) - mx(loc.longitude)) * S + W / 2, (my(ring[i + 1][1]) - my(loc.latitude)) * S + H / 2]
      const len = Math.hypot(b[0]! - a[0]!, b[1]! - a[1]!)
      if (len < 24) continue
      const nx = -(b[1]! - a[1]!) / len, ny = (b[0]! - a[0]!) / len
      for (const t of [0.35, 0.5, 0.65]) {
        const cx = a[0]! + (b[0]! - a[0]!) * t, cy = a[1]! + (b[1]! - a[1]!) * t
        if (cx < 14 || cy < 40 || cx > W - 60 || cy > H - 14) continue
        const at = (d: number) => G(cx + nx * d, cy + ny * d)
        const left = [-9, -8, -7].map(at), right = [7, 8, 9].map(at)
        const lb = (left[0]! + left[1]! + left[2]!) / 3, rb = (right[0]! + right[1]! + right[2]!) / 3
        // flat pink roof on both sides only
        if (Math.abs(lb - rb) > 2.5 || Math.max(...left) - Math.min(...left) > 2 || Math.max(...right) - Math.min(...right) > 2) continue
        if (R(cx + nx * 8, cy + ny * 8) - rb < 10 || R(cx - nx * 8, cy - ny * 8) - lb < 10 || lb < 190) continue
        const base = (lb + rb) / 2
        let ink = 0
        for (let d = -6; d <= 6; d += 0.5) ink += ((base - at(d)) / (base - 128)) * 0.5
        ;(stats[cls] ??= []).push(ink)
      }
    }
  }
  const med = (v: number[]) => { const s = [...v].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]!.toFixed(2) }
  const mean = (v: number[]) => (v.reduce((x, y) => x + y, 0) / v.length).toFixed(2)
  console.log(run, id, 'z' + loc.zoom, kind, Object.entries(stats).map(([k, v]) => `${k}: n=${v.length} mean=${mean(v)} med=${med(v)}`).join(' | '))
}
