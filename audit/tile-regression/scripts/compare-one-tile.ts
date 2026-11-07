/**
 * Compare one reference PNG vs one candidate PNG with pixelmatch.
 *
 * Usage:
 *   bun run scripts/compare-one-tile.ts --ref path/to/ref.png --cand path/to/cand.png
 *   bun run scripts/compare-one-tile.ts --tiles 17/70422/43008 --ref-dir /tmp/ref --cand-dir /tmp/cand
 *
 * Writes runs/<timestamp>/{ref,cand,diff}.png, metrics.json, index.html
 */
import { copyFile, mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

import pixelmatch from 'pixelmatch'
import { PNG } from 'pngjs'

const ROOT = path.resolve(import.meta.dir, '..')
const RUNS = path.join(ROOT, 'runs')

type Args = {
  ref?: string
  cand?: string
  tiles?: string
  refDir?: string
  candDir?: string
  out?: string
  threshold: number
}

function parseArgs(argv: string[]): Args {
  const out: Args = { threshold: 0.1 }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => {
      const v = argv[++i]
      if (v === undefined) throw new Error(`missing value for ${a}`)
      return v
    }
    if (a === '--ref') out.ref = next()
    else if (a === '--cand') out.cand = next()
    else if (a === '--tiles') out.tiles = next()
    else if (a === '--ref-dir') out.refDir = next()
    else if (a === '--cand-dir') out.candDir = next()
    else if (a === '--out') out.out = next()
    else if (a === '--threshold') out.threshold = Number(next())
    else if (a === '--help' || a === '-h') {
      console.log(`Usage:
  bun run scripts/compare-one-tile.ts --ref ref.png --cand cand.png [--out runs/…]
  bun run scripts/compare-one-tile.ts --tiles z/x/y --ref-dir DIR --cand-dir DIR`)
      process.exit(0)
    } else throw new Error(`unknown arg: ${a}`)
  }
  return out
}

function tilePngPath(dir: string, tiles: string): string {
  const parts = tiles.split('/')
  if (parts.length !== 3) throw new Error(`--tiles must be z/x/y, got ${tiles}`)
  return path.join(dir, parts[0]!, parts[1]!, `${parts[2]!}.png`)
}

function stamp(): string {
  const d = new Date()
  const p = (n: number, w = 2) => String(n).padStart(w, '0')
  return (
    `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}` +
    `-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
  )
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
  const [stdout, stderr, exit] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  if (exit !== 0) return null
  // dssim prints: "<score> <path>"
  const m = stdout.trim().match(/^([0-9.eE+-]+)/)
  if (!m) {
    console.warn(`[compare] dssim present but unparsed: ${stdout || stderr}`)
    return null
  }
  return Number(m[1])
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  let refPath = args.ref
  let candPath = args.cand
  if (args.tiles) {
    if (!args.refDir || !args.candDir) {
      throw new Error('--tiles requires --ref-dir and --cand-dir')
    }
    refPath = tilePngPath(args.refDir, args.tiles)
    candPath = tilePngPath(args.candDir, args.tiles)
  }
  if (!refPath || !candPath) {
    throw new Error('need --ref/--cand or --tiles with --ref-dir/--cand-dir')
  }

  const outDir = args.out ?? path.join(RUNS, stamp())
  await mkdir(outDir, { recursive: true })

  const destRef = path.join(outDir, 'ref.png')
  const destCand = path.join(outDir, 'cand.png')
  const destDiff = path.join(outDir, 'diff.png')
  await copyFile(refPath, destRef)
  await copyFile(candPath, destCand)

  const imgA = await readPng(destRef)
  const imgB = await readPng(destCand)
  if (imgA.width !== imgB.width || imgA.height !== imgB.height) {
    throw new Error(
      `size mismatch: ref ${imgA.width}×${imgA.height} vs cand ${imgB.width}×${imgB.height}`,
    )
  }
  const { width, height } = imgA
  const diff = new PNG({ width, height })
  const mismatched = pixelmatch(imgA.data, imgB.data, diff.data, width, height, {
    threshold: args.threshold,
  })
  await writeFile(destDiff, PNG.sync.write(diff))

  const total = width * height
  const ratio = mismatched / total
  const dssim = await optionalDssim(destRef, destCand)

  const metrics = {
    generated_at: new Date().toISOString(),
    ref: path.resolve(refPath),
    cand: path.resolve(candPath),
    tiles: args.tiles ?? null,
    width,
    height,
    threshold: args.threshold,
    mismatched,
    total_pixels: total,
    pixelmatch_ratio: ratio,
    dssim,
  }
  await writeFile(path.join(outDir, 'metrics.json'), JSON.stringify(metrics, null, 2) + '\n')

  const dssimLine =
    dssim === null
      ? '<dt>DSSIM</dt><dd>n/a (dssim not installed)</dd>'
      : `<dt>DSSIM</dt><dd>${dssim.toFixed(6)}</dd>`

  const html = `<!doctype html>
<html lang="en">
<meta charset="utf-8"/>
<title>One-tile compare</title>
<style>
  body { font-family: ui-sans-serif, system-ui, sans-serif; margin: 1.5rem; background: #111; color: #eee; }
  h1 { font-size: 1.2rem; font-weight: 600; }
  .meta { color: #9ca3af; font-size: 0.85rem; margin: 0.5rem 0 1.25rem; }
  dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.2rem 1rem; margin: 0 0 1.5rem; }
  dt { color: #9ca3af; } dd { margin: 0; font-variant-numeric: tabular-nums; }
  .row { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.75rem; }
  figure { margin: 0; background: #1c1c1c; border-radius: 8px; padding: 0.75rem; }
  figcaption { font-size: 0.8rem; color: #9ca3af; margin-bottom: 0.5rem; }
  img { width: 100%; height: auto; image-rendering: pixelated; background: #333; border-radius: 4px; }
</style>
<h1>One-tile compare${args.tiles ? ` · ${args.tiles}` : ''}</h1>
<p class="meta">${metrics.generated_at}</p>
<dl>
  <dt>pixelmatch ratio</dt><dd>${(ratio * 100).toFixed(3)}% (${mismatched.toLocaleString()} / ${total.toLocaleString()} px)</dd>
  <dt>threshold</dt><dd>${args.threshold}</dd>
  ${dssimLine}
  <dt>size</dt><dd>${width}×${height}</dd>
</dl>
<div class="row">
  <figure><figcaption>Reference (QGIS)</figcaption><img src="ref.png" alt="ref"/></figure>
  <figure><figcaption>Candidate (Rust)</figcaption><img src="cand.png" alt="cand"/></figure>
  <figure><figcaption>Diff (pixelmatch)</figcaption><img src="diff.png" alt="diff"/></figure>
</div>
</html>
`
  await writeFile(path.join(outDir, 'index.html'), html)

  console.log(`[compare] out → ${outDir}`)
  console.log(
    `[compare] pixelmatch=${(ratio * 100).toFixed(3)}% mismatched=${mismatched}` +
      (dssim === null ? '' : ` dssim=${dssim.toFixed(6)}`),
  )
  console.log(`[compare] gallery → ${path.join(outDir, 'index.html')}`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
