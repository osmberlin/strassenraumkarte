/**
 * Screenshot the four map viewers' headers and controls for a docs step folder,
 * and print console / page errors per viewer (a viewer is "clean" when none print).
 *
 * Usage: `STEP=before bun run scripts/capture-viewers.ts`  (or STEP=after)
 * Output: docs/viewers/<FOLDER>/<STEP>-<viewer>.png (FOLDER defaults to 01-catalyst-look)
 *
 * Needs the viewers running (see docs/VIEWERS.md):
 *   vector dev        http://127.0.0.1:5177   (bun run dev in vector/)
 *   QGIS run preview  http://127.0.0.1:8000   (./render/preview_server.py)
 *   design viewer     http://127.0.0.1:8017   (docs/design-research/tools/serve_viewer.sh)
 * Override the design viewer port with VIEWER_URL=… when 8017 is taken by another checkout.
 */
import { mkdir } from 'node:fs/promises'
import path from 'node:path'

import { chromium, type ConsoleMessage, type Page } from 'playwright'

const STEP = process.env.STEP ?? 'before'
const FOLDER = process.env.FOLDER ?? '01-catalyst-look'
const OUT = path.resolve(import.meta.dir, '../../docs/viewers', FOLDER)

const VIEWER_URL = process.env.VIEWER_URL ?? 'http://127.0.0.1:8017/'

const VIEWERS: { name: string; url: string }[] = [
  { name: 'vector-main', url: 'http://127.0.0.1:5177/#16/52.4768/13.4222' },
  {
    name: 'vector-compare',
    url: 'http://127.0.0.1:5177/?compare=1&location=intersection&mode=side-by-side&panes=qgis,rust,vector',
  },
  { name: 'qgis-preview', url: 'http://127.0.0.1:8000/preview.html' },
  {
    name: 'design-viewer',
    url: `${VIEWER_URL}#map=18/52.4758/13.42985&a=full-approx&b=qgis&mode=side`,
  },
]

const browser = await chromium.launch({
  headless: true,
  args: ['--use-gl=angle', '--use-angle=swiftshader-webgl'],
})
await mkdir(OUT, { recursive: true })

/** Errors that come from offline external hosts are not regressions of the viewers. */
const EXTERNAL = /^https?:\/\/(?!127\.0\.0\.1|localhost)/

for (const v of VIEWERS) {
  const page: Page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
  const problems: string[] = []
  page.on('console', (msg: ConsoleMessage) => {
    if (msg.type() === 'error' && !EXTERNAL.test(msg.location().url)) {
      problems.push(`console.error ${msg.text()}`)
    }
  })
  page.on('pageerror', (err) => problems.push(`pageerror ${err.message}`))
  page.on('requestfailed', (req) => {
    if (!EXTERNAL.test(req.url())) problems.push(`requestfailed ${req.url()} ${req.failure()?.errorText}`)
  })

  await page.goto(v.url, { waitUntil: 'load' })
  // the maps load tiles and the vector app paints after its style is ready
  await page.waitForTimeout(4000)
  const file = path.join(OUT, `${STEP}-${v.name}.png`)
  await page.screenshot({ path: file })
  console.log(`[${v.name}] ${file}`)
  for (const p of problems) console.log(`  ${p}`)
  if (problems.length === 0) console.log('  no console or page errors')
  await page.close()
}

await browser.close()
