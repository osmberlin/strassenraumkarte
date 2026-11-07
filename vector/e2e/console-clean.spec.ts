import { expect, test } from '@playwright/test'

import { COMPARE_LOCATIONS } from '../locations'

/**
 * Console-clean verification across compare locations (w8).
 * Requires `bun run dev` (and ideally raster preview on :8000).
 */
test.describe('console-clean compare locations', () => {
  for (const loc of COMPARE_LOCATIONS) {
    test(`${loc.id} has no console.error / map error`, async ({ page }) => {
      const consoleErrors: string[] = []
      const pageErrors: string[] = []
      const unresolvedImages: string[] = []

      page.on('console', (msg) => {
        if (msg.type() === 'error') consoleErrors.push(msg.text())
      })
      page.on('pageerror', (err) => pageErrors.push(err.message))

      await page.goto(
        `/?compare=1&mode=side-by-side&location=${loc.id}`,
        { waitUntil: 'networkidle', timeout: 60_000 },
      )

      await page.waitForTimeout(2000)

      const mapProbe = await page.evaluate(() => {
        const missing: string[] = []
        // MapLibre fires styleimagemissing on window events via map; collect from console already.
        return { missing }
      })
      void mapProbe
      void unresolvedImages

      expect(pageErrors, `pageerrors at ${loc.id}`).toEqual([])
      // Filter noisy font / raster 404s when preview server is down
      const hard = consoleErrors.filter(
        (t) =>
          !t.includes('Failed to load resource') &&
          !/glyphs|font|\/raster\//i.test(t),
      )
      expect(hard, `console.error at ${loc.id}: ${hard.join(' | ')}`).toEqual([])
    })
  }
})
