/**
 * Bun tests: metres helper + effects + validateStyleMin on buildStyle().
 *
 * Run: `bun test` or `bun run validate-style`
 */
import { describe, expect, test } from 'bun:test'
import { validateStyleMin } from '@maplibre/maplibre-gl-style-spec'

import { buildStyle } from './build-style'
import { dropShadow, innerShadow, outerGlow } from './effects'
import { metresToPixels, metresToPixelsAtZoom, mmToPixels } from './metres'
import { osmLayerFilter, OSM_LAYER_BUCKETS } from './order'
import { SOURCE_ID } from './source'

describe('metresToPixels', () => {
  test('matches closed-form factor at z15 and z20', () => {
    const m = 2
    const expr = metresToPixels(m)
    expect(expr[0]).toBe('interpolate')
    expect(expr[1]).toEqual(['exponential', 2])
    expect(expr[3]).toBe(15)
    expect(expr[4]).toBeCloseTo(metresToPixelsAtZoom(m, 15), 10)
    expect(expr[5]).toBe(20)
    expect(expr[6]).toBeCloseTo(metresToPixelsAtZoom(m, 20), 10)
  })

  test('wraps expression metre inputs', () => {
    const width = ['get', 'width'] as const
    const expr = metresToPixels(
      width as unknown as import('@maplibre/maplibre-gl-style-spec').ExpressionSpecification,
    )
    expect(Array.isArray(expr[4])).toBe(true)
    expect((expr[4] as unknown[])[0]).toBe('*')
  })

  test('mmToPixels uses 96 DPI', () => {
    expect(mmToPixels(25.4)).toBeCloseTo(96)
  })
})

describe('osmLayerFilter', () => {
  test('covers every bucket', () => {
    for (const b of OSM_LAYER_BUCKETS) {
      expect(osmLayerFilter(b.id)).toBeTruthy()
    }
  })
})

describe('effects', () => {
  const base = {
    source: SOURCE_ID,
    'source-layer': 'landuse',
    minzoom: 15,
  }

  test('helpers emit layers that validateStyleMin accepts', () => {
    const style = buildStyle({
      url: 'pmtiles://http://127.0.0.1:5177/tiles/strassenraumkarte.pmtiles',
    })
    style.layers.push(
      ...dropShadow('fx-landuse', base, {
        blurM: 1,
        offsetM: 0.4,
        angleDeg: 40,
        color: '#232323',
        opacity: 0.33,
      }),
      ...innerShadow('fx-water', base, { blurM: 4, color: '#a396d9', opacity: 0.5 }),
      ...outerGlow('fx-forest', base, { blurM: 0.75, color: '#c8dbb6' }),
    )
    const errors = validateStyleMin(style)
    expect(errors).toEqual([])
  })
})

describe('buildStyle', () => {
  test('validateStyleMin accepts the prep style', () => {
    const style = buildStyle({
      url: 'pmtiles://http://127.0.0.1:5177/tiles/strassenraumkarte.pmtiles',
    })
    const errors = validateStyleMin(style)
    expect(errors).toEqual([])
  })
})
