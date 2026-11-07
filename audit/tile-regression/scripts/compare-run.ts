/**
 * Batch tile compare: pixelmatch over a manifest suite → HTML gallery.
 *
 * Usage:
 *   bun run scripts/compare-run.ts \
 *     --ref-dir /tmp/srk-smoke-ref \
 *     --cand-dir /tmp/srk-smoke-cand \
 *     [--manifest manifest.json] [--suite smoke] [--threshold 0.1]
 *
 * Optional: --render invokes QGIS + Rust before comparing (prefer render-suite.sh).
 *
 * Exit codes (migration mode):
 *   0 — always, unless I/O / size mismatch / missing PNGs
 *   1 — only if any tile exceeds --hard-fail (default 0.5 = 50% mismatched pixels)
 * Soft bands (recorded in summary, do not fail): >5% = bad, >1% = review.
 */
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

import pixelmatch from 'pixelmatch'
import { PNG } from 'pngjs'

const ROOT = path.resolve(import.meta.dir, '..')
const RUNS = path.join(ROOT, 'runs')
const REPO = path.resolve(ROOT, '../..')

export type ManifestTile = {
  id: string
  z: number
  x: number
  y: number
  label: string
  strata: string[]
  suite: string
}

type Manifest = { tiles: ManifestTile[] }

type TileMetrics = {
  id: string
  z: number
  x: number
  y: number
  label: string
  strata: string[]
  suite: string
  width: number
  height: number
  mismatched: number
  total_pixels: number
  pixelmatch_ratio: number
  dssim: number | null
  band: 'ok' | 'review' | 'bad' | 'hard-fail'
  error?: string
}

type Args = {
  manifest: string
  suite: string
  refDir: string
  candDir: string
  out?: string
  threshold: number
  hardFail: number
  render: boolean
  layers: string
}

function parseArgs(argv: string[]): Args {
  const out: Args = {
    manifest: path.join(ROOT, 'manifest.json'),
    suite: 'smoke',
    refDir: '/tmp/srk-smoke-ref',
    candDir: '/tmp/srk-smoke-cand',
    threshold: 0.1,
    hardFail: 0.5,
    render: false,
    layers: 'highway_area',
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => {
      const v = argv[++i]
      if (v === undefined) throw new Error(`missing value for ${a}`)
      return v
    }
    if (a === '--manifest') out.manifest = path.resolve(next())
    else if (a === '--suite') out.suite = next()
    else if (a === '--ref-dir') out.refDir = next()
    else if (a === '--cand-dir') out.candDir = next()
    else if (a === '--out') out.out = next()
    else if (a === '--threshold') out.threshold = Number(next())
    else if (a === '--hard-fail') out.hardFail = Number(next())
    else if (a === '--render') out.render = true
    else if (a === '--layers') out.layers = next()
    else if (a === '--help' || a === '-h') {
      console.log(`Usage:
  bun run scripts/compare-run.ts --ref-dir DIR --cand-dir DIR [--manifest PATH] [--suite smoke]
  Options: --threshold 0.1 --hard-fail 0.5 --out runs/… --render --layers highway_area

Exit: 0 unless a tile pixelmatch_ratio > --hard-fail (default 0.5), or compare I/O fails.`)
      process.exit(0)
    } else throw new Error(`unknown arg: ${a}`)
  }
  return out
}

function stamp(): string {
  const d = new Date()
  const p = (n: number, w = 2) => String(n).padStart(w, '0')
  return (
    `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}` +
    `-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
  )
}

function tilePngPath(dir: string, z: number, x: number, y: number): string {
  return path.join(dir, String(z), String(x), `${y}.png`)
}

async function readPng(file: string): Promise<PNG> {
  const buf = Buffer.from(await Bun.file(file).arrayBuffer())
  return PNG.sync.read(buf)
}

async function optionalDssim(ref: string, cand: string): Promise<number | null> {
  let proc: ReturnType<typeof Bun.spawn>
  try {
    proc = Bun.spawn(['dssim', ref, cand], { stdout: 'pipe', stderr: 'pipe' })
  } catch {
    return null
  }
  const [stdout, , exit] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  if (exit !== 0) return null
  const m = stdout.trim().match(/^([0-9.eE+-]+)/)
  return m ? Number(m[1]) : null
}

function bandFor(ratio: number, hardFail: number): TileMetrics['band'] {
  if (ratio > hardFail) return 'hard-fail'
  if (ratio > 0.05) return 'bad'
  if (ratio > 0.01) return 'review'
  return 'ok'
}

async function runRender(tiles: ManifestTile[], args: Args): Promise<void> {
  const tileList = tiles.map((t) => t.id).join(',')
  console.log(`[compare-run] --render: QGIS → ${args.refDir}`)
  const qgis = Bun.spawn(
    [
      path.join(ROOT, 'scripts/render-qgis-tile.sh'),
      '--tiles',
      tileList,
      '--layers',
      args.layers,
      '--out',
      args.refDir,
    ],
    { cwd: REPO, stdout: 'inherit', stderr: 'inherit' },
  )
  if ((await qgis.exited) !== 0) throw new Error('QGIS render failed')

  const rustBin = path.join(REPO, 'rust/srk-render/target/release/srk-render')
  console.log(`[compare-run] --render: Rust → ${args.candDir}`)
  const rust = Bun.spawn(
    [rustBin, '--tiles', tileList, '--layers', args.layers, '--out', args.candDir, '--format', 'png'],
    { cwd: REPO, stdout: 'inherit', stderr: 'inherit', env: { ...process.env } },
  )
  if ((await rust.exited) !== 0) throw new Error('Rust render failed')
}

function pct(r: number): string {
  return `${(r * 100).toFixed(3)}%`
}

function escapeHtml(s: string): string {
  return s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
}

function buildGalleryHtml(
  suite: string,
  generatedAt: string,
  summary: Record<string, unknown>,
  tiles: TileMetrics[],
): string {
  const cards = tiles
    .map((t) => {
      const rel = `tiles/${t.z}/${t.x}/${t.y}`
      const dssim =
        t.dssim === null || t.dssim === undefined
          ? 'n/a'
          : t.dssim.toFixed(6)
      const err = t.error ? `<p class="err">${escapeHtml(t.error)}</p>` : ''
      return `<article class="card band-${t.band}">
  <header>
    <h2>${escapeHtml(t.label)}</h2>
    <p class="id">${escapeHtml(t.id)} · ${escapeHtml(t.strata.join(', '))}</p>
  </header>
  <dl>
    <dt>pixelmatch</dt><dd>${pct(t.pixelmatch_ratio)} (${t.mismatched.toLocaleString()} / ${t.total_pixels.toLocaleString()})</dd>
    <dt>band</dt><dd>${t.band}</dd>
    <dt>DSSIM</dt><dd>${dssim}</dd>
  </dl>
  ${err}
  <div class="row">
    <figure><figcaption>ref</figcaption><img src="${rel}/ref.png" alt="ref ${escapeHtml(t.id)}"/></figure>
    <figure><figcaption>cand</figcaption><img src="${rel}/cand.png" alt="cand ${escapeHtml(t.id)}"/></figure>
    <figure><figcaption>diff</figcaption><img src="${rel}/diff.png" alt="diff ${escapeHtml(t.id)}"/></figure>
  </div>
</article>`
    })
    .join('\n')

  const byZoom = summary.by_zoom as Record<string, { count: number; mean: number; max: number }>
  const zoomRows = Object.entries(byZoom)
    .sort(([a], [b]) => Number(a) - Number(b))
    .map(
      ([z, s]) =>
        `<tr><td>z${z}</td><td>${s.count}</td><td>${pct(s.mean)}</td><td>${pct(s.max)}</td></tr>`,
    )
    .join('')

  const worst = (summary.worst as TileMetrics[]).slice(0, 5)
  const worstList = worst
    .map((t) => `<li>${escapeHtml(t.id)} · ${escapeHtml(t.label)} · ${pct(t.pixelmatch_ratio)}</li>`)
    .join('')

  const bands = summary.bands as Record<string, number>
  const bandOk = bands.ok ?? 0
  const bandReview = bands.review ?? 0
  const bandBad = bands.bad ?? 0
  const bandHard = bands['hard-fail'] ?? 0
  const layer = String(summary.layer ?? 'highway_area')

  return `<!doctype html>
<html lang="en">
<meta charset="utf-8"/>
<title>Smoke suite · ${escapeHtml(suite)} · ${escapeHtml(layer)}</title>
<style>
  body { font-family: ui-sans-serif, system-ui, sans-serif; margin: 0; padding: 1.5rem; background: #111; color: #eee; }
  h1 { font-size: 1.25rem; font-weight: 600; margin: 0 0 0.35rem; }
  .meta { color: #9ca3af; font-size: 0.85rem; margin: 0 0 1.25rem; }
  .meta a { color: #93c5fd; }
  .summary { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.5rem; }
  @media (max-width: 800px) { .summary { grid-template-columns: 1fr; } }
  .panel { background: #1c1c1c; border-radius: 8px; padding: 1rem 1.1rem; }
  .panel h2 { font-size: 0.85rem; color: #9ca3af; font-weight: 500; margin: 0 0 0.6rem; text-transform: uppercase; letter-spacing: 0.04em; }
  dl.stats { display: grid; grid-template-columns: max-content 1fr; gap: 0.2rem 1rem; margin: 0; }
  dt { color: #9ca3af; } dd { margin: 0; font-variant-numeric: tabular-nums; }
  table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; font-size: 0.9rem; }
  th, td { text-align: left; padding: 0.25rem 0.5rem; border-bottom: 1px solid #333; }
  th { color: #9ca3af; font-weight: 500; }
  ul.worst { margin: 0; padding-left: 1.1rem; font-variant-numeric: tabular-nums; }
  .card { background: #1c1c1c; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; border-left: 3px solid #374151; }
  .card.band-ok { border-left-color: #16a34a; }
  .card.band-review { border-left-color: #ca8a04; }
  .card.band-bad { border-left-color: #ea580c; }
  .card.band-hard-fail { border-left-color: #dc2626; }
  .card header h2 { font-size: 1rem; margin: 0 0 0.2rem; }
  .card .id { color: #9ca3af; font-size: 0.8rem; margin: 0 0 0.75rem; }
  .card dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.15rem 1rem; margin: 0 0 0.75rem; font-size: 0.9rem; }
  .row { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.5rem; }
  figure { margin: 0; }
  figcaption { font-size: 0.75rem; color: #9ca3af; margin-bottom: 0.35rem; }
  img { width: 100%; height: auto; image-rendering: pixelated; background: #333; border-radius: 4px; }
  .err { color: #f87171; font-size: 0.85rem; }
</style>
<h1>Tile regression · ${escapeHtml(suite)}</h1>
<p class="meta">${escapeHtml(generatedAt)} · ${tiles.length} tiles · layer isolate <code>${escapeHtml(layer)}</code> · sorted by pixelmatch desc · <a href="summary.json">summary.json</a></p>
<div class="summary">
  <div class="panel">
    <h2>Overall</h2>
    <dl class="stats">
      <dt>layer isolate</dt><dd><code>${escapeHtml(layer)}</code></dd>
      <dt>mean pixelmatch</dt><dd>${pct(summary.mean_pixelmatch as number)}</dd>
      <dt>max pixelmatch</dt><dd>${pct(summary.max_pixelmatch as number)}</dd>
      <dt>ok / review / bad / hard-fail</dt>
      <dd>${bandOk} / ${bandReview} / ${bandBad} / ${bandHard}</dd>
      <dt>hard-fail threshold</dt><dd>${pct(summary.hard_fail_threshold as number)}</dd>
    </dl>
  </div>
  <div class="panel">
    <h2>Per zoom</h2>
    <table>
      <thead><tr><th>zoom</th><th>n</th><th>mean</th><th>max</th></tr></thead>
      <tbody>${zoomRows}</tbody>
    </table>
    <h2 style="margin-top:1rem">Worst</h2>
    <ul class="worst">${worstList}</ul>
  </div>
</div>
${cards}
</html>
`
}

async function compareTile(
  tile: ManifestTile,
  refDir: string,
  candDir: string,
  outTileDir: string,
  threshold: number,
  hardFail: number,
): Promise<TileMetrics> {
  const refPath = tilePngPath(refDir, tile.z, tile.x, tile.y)
  const candPath = tilePngPath(candDir, tile.z, tile.x, tile.y)
  await mkdir(outTileDir, { recursive: true })

  const base: Omit<TileMetrics, 'width' | 'height' | 'mismatched' | 'total_pixels' | 'pixelmatch_ratio' | 'dssim' | 'band'> =
    {
      id: tile.id,
      z: tile.z,
      x: tile.x,
      y: tile.y,
      label: tile.label,
      strata: tile.strata,
      suite: tile.suite,
    }

  if (!(await Bun.file(refPath).exists())) {
    return {
      ...base,
      width: 0,
      height: 0,
      mismatched: 0,
      total_pixels: 0,
      pixelmatch_ratio: 1,
      dssim: null,
      band: 'hard-fail',
      error: `missing ref: ${refPath}`,
    }
  }
  if (!(await Bun.file(candPath).exists())) {
    return {
      ...base,
      width: 0,
      height: 0,
      mismatched: 0,
      total_pixels: 0,
      pixelmatch_ratio: 1,
      dssim: null,
      band: 'hard-fail',
      error: `missing cand: ${candPath}`,
    }
  }

  const destRef = path.join(outTileDir, 'ref.png')
  const destCand = path.join(outTileDir, 'cand.png')
  const destDiff = path.join(outTileDir, 'diff.png')
  await copyFile(refPath, destRef)
  await copyFile(candPath, destCand)

  const imgA = await readPng(destRef)
  const imgB = await readPng(destCand)
  if (imgA.width !== imgB.width || imgA.height !== imgB.height) {
    throw new Error(
      `${tile.id}: size mismatch ref ${imgA.width}×${imgA.height} vs cand ${imgB.width}×${imgB.height}`,
    )
  }
  const { width, height } = imgA
  const diff = new PNG({ width, height })
  const mismatched = pixelmatch(imgA.data, imgB.data, diff.data, width, height, {
    threshold,
  })
  await writeFile(destDiff, PNG.sync.write(diff))

  const total = width * height
  const ratio = mismatched / total
  const dssim = await optionalDssim(destRef, destCand)

  return {
    ...base,
    width,
    height,
    mismatched,
    total_pixels: total,
    pixelmatch_ratio: ratio,
    dssim,
    band: bandFor(ratio, hardFail),
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const raw = JSON.parse(await readFile(args.manifest, 'utf8')) as Manifest
  const tiles = raw.tiles.filter((t) => t.suite === args.suite)
  if (tiles.length === 0) {
    throw new Error(`no tiles with suite=${args.suite} in ${args.manifest}`)
  }

  if (args.render) {
    await runRender(tiles, args)
  }

  const outDir = args.out ?? path.join(RUNS, `${stamp()}-${args.suite}`)
  await mkdir(outDir, { recursive: true })

  const results: TileMetrics[] = []
  for (const tile of tiles) {
    const outTileDir = path.join(outDir, 'tiles', String(tile.z), String(tile.x), String(tile.y))
    console.log(`[compare-run] ${tile.id} · ${tile.label}`)
    const m = await compareTile(tile, args.refDir, args.candDir, outTileDir, args.threshold, args.hardFail)
    results.push(m)
    console.log(
      `  pixelmatch=${pct(m.pixelmatch_ratio)} band=${m.band}` +
        (m.error ? ` ERR=${m.error}` : ''),
    )
  }

  const sorted = [...results].sort((a, b) => b.pixelmatch_ratio - a.pixelmatch_ratio)
  const ratios = results.map((r) => r.pixelmatch_ratio)
  const mean = ratios.reduce((a, b) => a + b, 0) / ratios.length
  const max = Math.max(...ratios)

  const bands: Record<string, number> = { ok: 0, review: 0, bad: 0, 'hard-fail': 0 }
  for (const r of results) bands[r.band] = (bands[r.band] ?? 0) + 1

  const byZoom: Record<string, { count: number; mean: number; max: number; sum: number }> = {}
  for (const r of results) {
    const k = String(r.z)
    if (!byZoom[k]) byZoom[k] = { count: 0, mean: 0, max: 0, sum: 0 }
    const z = byZoom[k]!
    z.count++
    z.sum += r.pixelmatch_ratio
    z.max = Math.max(z.max, r.pixelmatch_ratio)
  }
  const by_zoom: Record<string, { count: number; mean: number; max: number }> = {}
  for (const [k, v] of Object.entries(byZoom)) {
    by_zoom[k] = { count: v.count, mean: v.sum / v.count, max: v.max }
  }

  const generatedAt = new Date().toISOString()
  const summary = {
    generated_at: generatedAt,
    suite: args.suite,
    layer: args.layers,
    tile_count: results.length,
    threshold: args.threshold,
    hard_fail_threshold: args.hardFail,
    mean_pixelmatch: mean,
    max_pixelmatch: max,
    bands,
    by_zoom,
    worst: sorted.slice(0, 5).map((t) => ({
      id: t.id,
      label: t.label,
      pixelmatch_ratio: t.pixelmatch_ratio,
      band: t.band,
    })),
    exit_policy:
      'Exit 1 only if any tile pixelmatch_ratio > hard_fail (default 0.5). Softer bands (review>1%, bad>5%) are informational during migration.',
    ref_dir: path.resolve(args.refDir),
    cand_dir: path.resolve(args.candDir),
    manifest: path.resolve(args.manifest),
  }

  const jsonl = sorted.map((r) => JSON.stringify(r)).join('\n') + '\n'
  await writeFile(path.join(outDir, 'tiles.jsonl'), jsonl)
  await writeFile(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 2) + '\n')
  await writeFile(
    path.join(outDir, 'index.html'),
    buildGalleryHtml(args.suite, generatedAt, summary, sorted),
  )

  console.log(`[compare-run] out → ${outDir}`)
  console.log(
    `[compare-run] mean=${pct(mean)} max=${pct(max)} bands=${JSON.stringify(bands)}`,
  )
  console.log(`[compare-run] gallery → ${path.join(outDir, 'index.html')}`)

  const hardFails = results.filter((r) => r.band === 'hard-fail')
  if (hardFails.length > 0) {
    console.error(
      `[compare-run] HARD FAIL: ${hardFails.length} tile(s) > ${pct(args.hardFail)}: ${hardFails.map((t) => t.id).join(', ')}`,
    )
    process.exit(1)
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
