/**
 * Capture raster vs vector at each compare location, pixelmatch, write gallery.
 *
 * Prerequisites: `bun run dev` and preferably `./render/preview_server.py` for raster.
 *
 * Usage: `bun run screenshots`
 */
import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

import { chromium } from 'playwright'
import pixelmatch from 'pixelmatch'
import { PNG } from 'pngjs'

import { COMPARE_LOCATIONS } from '../locations'

const ROOT = path.resolve(import.meta.dir, '..')
// SHOT_OUT lets before/after runs live side by side (e.g. compare-output/before).
const OUT = path.resolve(ROOT, process.env.SHOT_OUT ?? 'compare-output')
const BASE = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177'
const VIEWPORT = { width: 1280, height: 800 }

async function readPng(file: string): Promise<PNG> {
  const buf = Buffer.from(await Bun.file(file).arrayBuffer())
  return PNG.sync.read(buf)
}

function cropRgba(img: PNG, width: number, height: number): Buffer {
  if (img.width === width && img.height === height) return img.data
  const out = Buffer.alloc(width * height * 4)
  for (let y = 0; y < height; y++) {
    img.data.copy(out, y * width * 4, y * img.width * 4, (y * img.width + width) * 4)
  }
  return out
}

async function main() {
  await mkdir(OUT, { recursive: true })
  const browser = await chromium.launch({
    headless: true,
    args: ['--use-gl=angle', '--use-angle=swiftshader-webgl'],
  })
  const page = await browser.newPage({ viewport: VIEWPORT })

  const rows: {
    id: string
    label: string
    diff: number
    raster: string
    vector: string
    diffPng: string
  }[] = []

  for (const loc of COMPARE_LOCATIONS) {
    // Explicit panes: the default also shows the Rust raster pane, which would be nth(1).
    const url = `${BASE}/?compare=1&mode=side-by-side&panes=qgis,vector&location=${loc.id}`
    console.log(`[shot] ${loc.id} ← ${url}`)
    await page.goto(url, { waitUntil: 'networkidle', timeout: 60_000 })
    await page.waitForTimeout(2500)

    const panes = page.locator('.compare-pane')
    const count = await panes.count()
    if (count !== 2) throw new Error(`expected 2 panes at ${loc.id}, got ${count}`)

    const rasterPath = path.join(OUT, `${loc.id}-raster.png`)
    const vectorPath = path.join(OUT, `${loc.id}-vector.png`)
    const diffPath = path.join(OUT, `${loc.id}-diff.png`)

    await panes.nth(0).screenshot({ path: rasterPath })
    await panes.nth(1).screenshot({ path: vectorPath })

    // Panes can differ by a pixel (flex rounding) — compare the common top-left area.
    const imgA = await readPng(rasterPath)
    const imgB = await readPng(vectorPath)
    const width = Math.min(imgA.width, imgB.width)
    const height = Math.min(imgA.height, imgB.height)
    const diff = new PNG({ width, height })
    const mismatched = pixelmatch(
      cropRgba(imgA, width, height),
      cropRgba(imgB, width, height),
      diff.data,
      width,
      height,
      { threshold: 0.1 },
    )
    await writeFile(diffPath, PNG.sync.write(diff))
    const score = mismatched / (width * height)
    rows.push({
      id: loc.id,
      label: loc.label,
      diff: score,
      raster: path.basename(rasterPath),
      vector: path.basename(vectorPath),
      diffPng: path.basename(diffPath),
    })
    console.log(`[shot] ${loc.id} diff=${(score * 100).toFixed(2)}% (${mismatched} px)`)
  }

  rows.sort((a, b) => b.diff - a.diff)

  const html = `<!doctype html>
<html lang="en">
<meta charset="utf-8"/>
<title>Straßenraumkarte raster/vector compare</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 1.5rem; background: #111; color: #eee; }
  h1 { font-size: 1.25rem; }
  .card { margin: 1.5rem 0; padding: 1rem; background: #1c1c1c; border-radius: 8px; }
  .row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.75rem; }
  img { width: 100%; height: auto; background: #333; }
  .meta { color: #aaa; font-size: 0.85rem; margin-bottom: 0.75rem; }
</style>
<h1>Raster / vector / diff (sorted by mismatch)</h1>
<p class="meta">Generated ${new Date().toISOString()} · viewport ${VIEWPORT.width}×${VIEWPORT.height}</p>
${rows
  .map(
    (r) => `
<section class="card">
  <h2>${r.label} <span class="meta">(${r.id}) · ${(r.diff * 100).toFixed(2)}% diff</span></h2>
  <div class="row">
    <figure><figcaption>Raster</figcaption><img src="${r.raster}" alt="raster"/></figure>
    <figure><figcaption>Vector</figcaption><img src="${r.vector}" alt="vector"/></figure>
    <figure><figcaption>Diff</figcaption><img src="${r.diffPng}" alt="diff"/></figure>
  </div>
</section>`,
  )
  .join('\n')}
</html>`

  await writeFile(path.join(OUT, 'index.html'), html)
  await writeFile(path.join(OUT, 'scores.json'), JSON.stringify(rows, null, 2))
  console.log(`[shot] gallery → ${path.join(OUT, 'index.html')}`)

  await browser.close()
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
