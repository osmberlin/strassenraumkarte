import { chromium } from 'playwright'

const url = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/'
const out = process.env.OUT ?? '../tmp/vector-preview-playwright.png'

const browser = await chromium.launch({
  headless: true,
  args: ['--use-gl=angle', '--use-angle=swiftshader-webgl'],
})
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })

page.on('console', (msg) => {
  if (msg.type() === 'error') console.error('[console.error]', msg.text())
})
page.on('pageerror', (err) => console.error('[pageerror]', err.message))

await page.goto(url, { waitUntil: 'networkidle' })

await page.waitForFunction(
  () => {
    const el = document.querySelector('.bar .ok, .bar .err')
    const t = el?.textContent ?? ''
    return t.startsWith('idle') || t.startsWith('Map loaded')
  },
  { timeout: 30000 },
)

await page.waitForTimeout(1000)

const status = await page.locator('.bar').innerText()
const probe = await page.evaluate(() => {
  const m = (window as unknown as { __srkMap?: any }).__srkMap
  const tm = m?.style?.tileManagers?.strassenraumkarte
  const ids = tm?.getIds?.() ?? []
  return {
    loaded: m?.loaded?.(),
    styleLoaded: m?.isStyleLoaded?.(),
    tileCount: ids.length,
    renderable: tm?.getRenderableIds?.()?.length ?? 0,
  }
})

console.log('STATUS:\n', status)
console.log('PROBE:', JSON.stringify(probe, null, 2))

if (!probe.loaded || (probe.renderable ?? 0) < 1) {
  throw new Error('Preview did not load renderable tiles')
}

await page.screenshot({ path: out, fullPage: true })
console.log('Wrote', out)

await browser.close()
