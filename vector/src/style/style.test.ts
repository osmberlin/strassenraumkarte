/**
 * Bun tests: metres helper + effects + validateStyleMin on buildStyle().
 *
 * Run: `bun test` or `bun run validate-style`
 */
import { describe, expect, test } from 'bun:test'
import { validateStyleMin } from '@maplibre/maplibre-gl-style-spec'
import type { CircleLayerSpecification, LineLayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { buildStyle } from './build-style'
import {
  dropShadow,
  highwayInnerBlur,
  innerGlow,
  innerShadow,
  outerGlow,
} from './effects'
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

  test('coalesces null/missing layer so MapLibre never compares null as a number', () => {
    for (const b of OSM_LAYER_BUCKETS) {
      const filter = osmLayerFilter(b.id) as unknown[]
      // ['<=|'=='|'>=', ['coalesce', ['get', 'layer'], 0], n]
      expect(filter[1]).toEqual(['coalesce', ['get', 'layer'], 0])
    }
    expect(osmLayerFilter('l0')).toEqual([
      '==',
      ['coalesce', ['get', 'layer'], 0],
      0,
    ])
    expect(osmLayerFilter('lm2')).toEqual([
      '<=',
      ['coalesce', ['get', 'layer'], 0],
      -2,
    ])
    expect(osmLayerFilter('l3p')).toEqual([
      '>=',
      ['coalesce', ['get', 'layer'], 0],
      3,
    ])
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
      ...innerGlow('fx-glacier', base, { blurM: 0.75, color: '#ebe9f2' }),
      ...highwayInnerBlur('fx-highway-blur', base),
    )
    const errors = validateStyleMin(style)
    expect(errors).toEqual([])
  })

  test('dropShadow: line-width === line-blur (same ref); fill-translate === line-translate', () => {
    const [fill, outline] = dropShadow('ds', base, {
      blurM: 1,
      offsetM: 0.4,
      angleDeg: 40,
      color: '#232323',
      opacity: 0.33,
    })
    expect(fill.type).toBe('fill')
    expect(outline.type).toBe('line')
    const line = outline as LineLayerSpecification
    expect(line.paint?.['line-width']).toBe(line.paint?.['line-blur'])
    expect(fill.paint?.['fill-translate']).toBe(line.paint?.['line-translate'])
  })

  test('innerShadow: line-offset negative at stops; width equals blur when widthM omitted', () => {
    const [line] = innerShadow('is', base, { blurM: 4, color: '#000' }) as LineLayerSpecification[]
    expect(line.paint?.['line-width']).toEqual(line.paint?.['line-blur'])
    const offset = line.paint?.['line-offset'] as unknown[]
    expect(offset[0]).toBe('interpolate')
    // stops: z15 value at [4], z20 at [6]
    expect(offset[4] as number).toBeLessThan(0)
    expect(offset[6] as number).toBeLessThan(0)
  })

  test('outerGlow: dual layers; outer width stop > inner; each matched blur', () => {
    const [outer, inner] = outerGlow('og', base, {
      blurM: 0.75,
      color: '#c8dbb6',
    }) as LineLayerSpecification[]
    expect(outer.id).toContain('glow-outer')
    expect(inner.id).toContain('glow-inner')
    expect(outer.paint?.['line-width']).toBe(outer.paint?.['line-blur'])
    expect(inner.paint?.['line-width']).toBe(inner.paint?.['line-blur'])
    const outerW = outer.paint?.['line-width'] as unknown[]
    const innerW = inner.paint?.['line-width'] as unknown[]
    expect(outerW[4] as number).toBeGreaterThan(innerW[4] as number)
  })

  test('highwayInnerBlur: line-offset present and width === blur (same ref)', () => {
    const [line] = highwayInnerBlur('hw', base) as LineLayerSpecification[]
    expect(line.paint?.['line-width']).toBe(line.paint?.['line-blur'])
    expect(line.paint?.['line-offset']).toBeDefined()
    const offset = line.paint?.['line-offset'] as unknown[]
    expect(offset[0]).toBe('interpolate')
    expect(offset[4] as number).toBeLessThan(0)
    expect(line.paint?.['line-opacity']).toBe(0.67)
  })

  test('innerGlow: dual layers with negative offsets and matched blur', () => {
    const [outer, inner] = innerGlow('ig', base, {
      blurM: 0.75,
      color: '#ebe9f2',
    }) as LineLayerSpecification[]
    expect(outer.paint?.['line-width']).toBe(outer.paint?.['line-blur'])
    expect(inner.paint?.['line-width']).toBe(inner.paint?.['line-blur'])
    const outerOff = outer.paint?.['line-offset'] as unknown[]
    const innerOff = inner.paint?.['line-offset'] as unknown[]
    expect(outerOff[4] as number).toBeLessThan(0)
    expect(innerOff[4] as number).toBeLessThan(0)
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

  test('highway blur layers have line-offset and width===blur', () => {
    const style = buildStyle({
      url: 'pmtiles://http://127.0.0.1:5177/tiles/strassenraumkarte.pmtiles',
    })
    const blurLayers = style.layers.filter(
      (l): l is LineLayerSpecification =>
        l.type === 'line' && l.id.startsWith('highway_area-blur-'),
    )
    expect(blurLayers.length).toBe(OSM_LAYER_BUCKETS.length)
    for (const layer of blurLayers) {
      expect(layer.paint?.['line-width']).toBe(layer.paint?.['line-blur'])
      expect(layer.paint?.['line-offset']).toBeDefined()
      expect(layer.paint?.['line-opacity']).toBe(0.67)
    }
  })

  test('paint sandwich: markings before buildings, trees after', () => {
    const style = buildStyle({
      url: 'pmtiles://http://127.0.0.1:5177/tiles/strassenraumkarte.pmtiles',
    })
    const ids = style.layers.map((l) => l.id)
    const markingIdx = ids.findIndex((id) => id.startsWith('road_marking_'))
    const buildingIdx = ids.indexOf('building-shade-fill')
    const treeIdx = ids.indexOf('tree-crown')
    expect(markingIdx).toBeGreaterThanOrEqual(0)
    expect(buildingIdx).toBeGreaterThan(markingIdx)
    expect(treeIdx).toBeGreaterThan(buildingIdx)
  })

  test('tree crown shadow radius halves diameter_crown', () => {
    const style = buildStyle({
      url: 'pmtiles://http://127.0.0.1:5177/tiles/strassenraumkarte.pmtiles',
    })
    const shadow = style.layers.find((l) => l.id === 'tree-crown-shadow') as
      | CircleLayerSpecification
      | undefined
    expect(shadow).toBeDefined()
    const radius = shadow!.paint?.['circle-radius'] as unknown[]
    // ['interpolate', …, 17, ['*', ['/', coalesce…, 2], factor], …]
    const z17 = radius[4] as unknown[]
    expect(z17[0]).toBe('*')
    const half = z17[1] as unknown[]
    expect(half[0]).toBe('/')
    expect(half[2]).toBe(2)
  })
})
