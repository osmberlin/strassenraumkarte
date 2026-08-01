import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import {
  HIGHWAY_BLUR,
  PATH_ACCESS_AISLE,
  PATH_CASING_DARK,
  PATH_CASING_LIGHT,
  PATH_CYCLEWAY,
  PATH_FOOTWAY,
  PATH_SIDEWALK,
  PATH_STEPS,
  SERVICE_LINE,
  TACTILE,
} from '../colors'
import { HIGHWAY_INNER_BLUR_MM } from '../effects'
import { highwayAreaFillMatch, withOsmBucket } from '../expr'
import { mmToPixels, metresToPixels, metresToPixelsFromProp } from '../metres'
import { OSM_LAYER_BUCKETS, styleLayerId, type OsmLayerBucketId } from '../order'

/** Collapsed z14–z20 highway edge blur (MM paper units → px). */
function highwayBlurPx(): unknown[] {
  const expr: unknown[] = ['interpolate', ['linear'], ['zoom']]
  for (const { zoom, mm } of HIGHWAY_INNER_BLUR_MM) {
    expr.push(zoom, mmToPixels(mm))
  }
  return expr
}

/** Fill width inset by 0.2 m for casing (sidewalk / sidepath / footway). */
function pathFillWidthInset(fallbackM: number): ExpressionSpecification {
  return metresToPixels([
    '-',
    ['coalesce', ['get', 'width'], fallbackM],
    0.2,
  ] as ExpressionSpecification)
}

/** ±half feature width (default half of fallback). */
function halfWidthOffset(fallbackFullM: number, sign: 1 | -1): ExpressionSpecification {
  return metresToPixels([
    '*',
    ['/', ['coalesce', ['get', 'width'], fallbackFullM], 2],
    sign,
  ] as ExpressionSpecification)
}

/** Informal casing uses max(width, 1) / 2. */
function informalHalfOffset(sign: 1 | -1): ExpressionSpecification {
  return metresToPixels([
    '*',
    ['/', ['max', ['coalesce', ['get', 'width'], 1], 1], 2],
    sign,
  ] as ExpressionSpecification)
}

/**
 * Service default width: alley / missing class → 4 m; else (driveway, …) → 3 m.
 * QGIS: `"class" IS NULL OR "class" IN ('alley')` vs ELSE.
 */
function serviceWidthPx(): ExpressionSpecification {
  const fallback = [
    'match',
    ['coalesce', ['get', 'class'], ''],
    '',
    4,
    'alley',
    4,
    3,
  ] as ExpressionSpecification
  const lat = 52.48
  const z15 = 2 ** 15 / (78271.51696 * Math.cos((lat * Math.PI) / 180))
  const z20 = 2 ** 20 / (78271.51696 * Math.cos((lat * Math.PI) / 180))
  const value = ['coalesce', ['get', 'width'], fallback] as ExpressionSpecification
  return [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    15,
    ['*', value, z15],
    20,
    ['*', value, z20],
  ] as ExpressionSpecification
}

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

function pathCasingPair(
  layers: LayerSpecification[],
  bucketId: OsmLayerBucketId,
  role: string,
  filter: FilterSpecification,
  color: string,
  opacity: number,
  offsetPos: ExpressionSpecification,
  offsetNeg: ExpressionSpecification,
  dasharray: [number, number],
): void {
  for (const [side, offset] of [
    ['pos', offsetPos],
    ['neg', offsetNeg],
  ] as const) {
    layers.push({
      id: styleLayerId('highway_path', `casing-${role}-${side}`, bucketId),
      type: 'line',
      ...withOsmBucket('highway_path', 15, bucketId, filter),
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': color,
        'line-opacity': opacity,
        'line-width': metresToPixels(0.2),
        'line-offset': offset,
        'line-dasharray': dasharray,
      },
    })
  }
}

/** Streets: per OSM bucket — path → service → tactile → highway_area + blur + textures. */
export function streetLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []
  const blurRamp = highwayBlurPx()

  for (const bucket of OSM_LAYER_BUCKETS) {
    const b = bucket.id

    // --- path fills ---
    layers.push({
      id: styleLayerId('highway_path', 'fill-cycleway', b),
      type: 'line',
      ...withOsmBucket(
        'highway_path',
        15,
        b,
        f([
          'all',
          ['==', ['get', 'highway'], 'cycleway'],
          ['!=', ['get', 'informal'], 'yes'],
        ]),
      ),
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': PATH_CYCLEWAY,
        'line-width': metresToPixelsFromProp('width', 1),
      },
    })

    layers.push({
      id: styleLayerId('highway_path', 'fill-sidewalk', b),
      type: 'line',
      ...withOsmBucket(
        'highway_path',
        15,
        b,
        f([
          'all',
          ['in', ['get', 'class'], ['literal', ['sidewalk', 'crossing', 'link']]],
          ['!=', ['get', 'tunnel'], 'yes'],
          ['!=', ['get', 'informal'], 'yes'],
          ['!=', ['get', 'highway'], 'cycleway'],
        ]),
      ),
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': PATH_SIDEWALK,
        'line-width': pathFillWidthInset(1.8),
      },
    })

    layers.push({
      id: styleLayerId('highway_path', 'fill-sidepath', b),
      type: 'line',
      ...withOsmBucket(
        'highway_path',
        15,
        b,
        f([
          'all',
          ['==', ['get', 'highway'], 'path'],
          ['==', ['get', 'is_sidepath'], 'yes'],
          ['!=', ['get', 'tunnel'], 'yes'],
          ['!=', ['get', 'informal'], 'yes'],
          ['!', ['in', ['get', 'class'], ['literal', ['sidewalk', 'crossing', 'link']]]],
        ]),
      ),
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': PATH_SIDEWALK,
        'line-width': pathFillWidthInset(1.8),
      },
    })

    layers.push({
      id: styleLayerId('highway_path', 'fill-footway', b),
      type: 'line',
      ...withOsmBucket(
        'highway_path',
        15,
        b,
        f([
          'all',
          ['!=', ['get', 'tunnel'], 'yes'],
          ['!=', ['get', 'informal'], 'yes'],
          ['!', ['in', ['get', 'class'], ['literal', ['sidewalk', 'crossing', 'link']]]],
          ['!=', ['get', 'is_sidepath'], 'yes'],
          ['!=', ['get', 'class'], 'access_aisle'],
          ['!=', ['get', 'highway'], 'cycleway'],
          ['!=', ['get', 'highway'], 'steps'],
        ]),
      ),
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': PATH_FOOTWAY,
        'line-width': pathFillWidthInset(1.8),
      },
    })

    // Steps: footway-coloured base + hash-like dashed overlay (HashLine approx).
    layers.push({
      id: styleLayerId('highway_path', 'fill-steps-base', b),
      type: 'line',
      ...withOsmBucket(
        'highway_path',
        15,
        b,
        f([
          'all',
          ['==', ['get', 'highway'], 'steps'],
          ['!=', ['get', 'tunnel'], 'yes'],
          ['!=', ['get', 'informal'], 'yes'],
        ]),
      ),
      layout: { 'line-cap': 'butt', 'line-join': 'round' },
      paint: {
        'line-color': PATH_FOOTWAY,
        'line-width': pathFillWidthInset(1.8),
      },
    })
    layers.push({
      id: styleLayerId('highway_path', 'fill-steps-hash', b),
      type: 'line',
      ...withOsmBucket(
        'highway_path',
        15,
        b,
        f(['all', ['==', ['get', 'highway'], 'steps'], ['!=', ['get', 'tunnel'], 'yes']]),
      ),
      layout: { 'line-cap': 'butt', 'line-join': 'miter' },
      paint: {
        'line-color': PATH_STEPS,
        'line-width': metresToPixelsFromProp('width', 1.8),
        'line-dasharray': [0.05, 0.28],
      },
    })

    layers.push({
      id: styleLayerId('highway_path', 'fill-informal', b),
      type: 'line',
      ...withOsmBucket('highway_path', 15, b, f(['==', ['get', 'informal'], 'yes'])),
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': PATH_FOOTWAY,
        'line-opacity': 0.67,
        'line-width': metresToPixels([
          'max',
          ['coalesce', ['get', 'width'], 1],
          1,
        ] as ExpressionSpecification),
      },
    })

    layers.push({
      id: styleLayerId('highway_path', 'fill-access-aisle', b),
      type: 'line',
      ...withOsmBucket('highway_path', 15, b, f(['==', ['get', 'class'], 'access_aisle'])),
      layout: { 'line-cap': 'butt', 'line-join': 'miter' },
      paint: {
        'line-color': PATH_ACCESS_AISLE,
        'line-width': metresToPixels(2),
        'line-dasharray': [0.25, 0.25],
      },
    })

    // --- path casings at ±half-width ---
    // Dash 0.6;0.6 m on 0.2 m stroke → [3, 3]; informal 0.6;2.4 → [3, 12].
    pathCasingPair(
      layers,
      b,
      'sidewalk',
      f([
        'all',
        ['in', ['get', 'class'], ['literal', ['sidewalk', 'crossing', 'link']]],
        ['!=', ['get', 'tunnel'], 'yes'],
        ['!=', ['get', 'informal'], 'yes'],
        ['!=', ['get', 'highway'], 'cycleway'],
      ]),
      PATH_CASING_LIGHT,
      0.5,
      halfWidthOffset(1.8, 1),
      halfWidthOffset(1.8, -1),
      [3, 3],
    )
    pathCasingPair(
      layers,
      b,
      'sidepath',
      f([
        'all',
        ['==', ['get', 'highway'], 'path'],
        ['==', ['get', 'is_sidepath'], 'yes'],
        ['!=', ['get', 'tunnel'], 'yes'],
        ['!=', ['get', 'informal'], 'yes'],
        ['!', ['in', ['get', 'class'], ['literal', ['sidewalk', 'crossing', 'link']]]],
      ]),
      PATH_CASING_LIGHT,
      0.5,
      halfWidthOffset(1.8, 1),
      halfWidthOffset(1.8, -1),
      [3, 3],
    )
    pathCasingPair(
      layers,
      b,
      'footway',
      f([
        'all',
        ['!=', ['get', 'tunnel'], 'yes'],
        ['!=', ['get', 'informal'], 'yes'],
        ['!', ['in', ['get', 'class'], ['literal', ['sidewalk', 'crossing', 'link']]]],
        ['!=', ['get', 'is_sidepath'], 'yes'],
        ['!=', ['get', 'class'], 'access_aisle'],
        ['!=', ['get', 'highway'], 'cycleway'],
        ['!=', ['get', 'highway'], 'steps'],
      ]),
      PATH_CASING_DARK,
      1,
      halfWidthOffset(1.8, 1),
      halfWidthOffset(1.8, -1),
      [3, 3],
    )
    pathCasingPair(
      layers,
      b,
      'informal',
      f(['==', ['get', 'informal'], 'yes']),
      PATH_CASING_DARK,
      1,
      informalHalfOffset(1),
      informalHalfOffset(-1),
      [3, 12],
    )

    // --- service (alley/NULL → 4 m, driveway/else → 3 m) ---
    layers.push({
      id: styleLayerId('highway_service', 'line', b),
      type: 'line',
      ...withOsmBucket('highway_service', 15, b),
      layout: { 'line-cap': 'butt', 'line-join': 'round' },
      paint: {
        'line-color': SERVICE_LINE,
        'line-width': serviceWidthPx(),
      },
    })

    // --- tactile (offset kerb line; MarkerLine cross2 omitted — Known deviation) ---
    layers.push({
      id: styleLayerId('tactile_paving', 'line', b),
      type: 'line',
      ...withOsmBucket(
        'tactile_paving',
        17,
        b,
        f(['in', ['get', 'class'], ['literal', ['kerb', 'highway']]]),
      ),
      layout: { 'line-cap': 'butt', 'line-join': 'round' },
      paint: {
        'line-color': TACTILE,
        'line-width': metresToPixels(1),
        'line-offset': metresToPixels(-0.5),
      },
    })

    // --- highway_area fill + blur + surface textures ---
    const areaBase = withOsmBucket('highway_area', 15, b)
    layers.push({
      id: styleLayerId('highway_area', 'fill', b),
      type: 'fill',
      ...areaBase,
      paint: {
        'fill-color': highwayAreaFillMatch(),
        'fill-opacity': 1,
      },
    })

    layers.push({
      id: styleLayerId('highway_area', 'blur', b),
      type: 'line',
      ...areaBase,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': HIGHWAY_BLUR,
        'line-opacity': 0.85,
        'line-width': blurRamp as never,
        'line-blur': blurRamp as never,
      },
    })

    // Surface textures from the packed sprite. Rotation / ground-metre scale dropped (G0.4).
    for (const [surface, pattern, opacity] of [
      ['asphalt', 'surface/asphalt', 0.06],
      ['concrete', 'surface/concrete', 0.35],
      ['concrete:plates', 'surface/concrete', 0.35],
      ['paving_stones', 'surface/paving_stones', 0.1],
      ['sett', 'surface/sett', 0.12],
    ] as const) {
      layers.push({
        id: styleLayerId('highway_area', `pattern-${surface.replace(':', '-')}`, b),
        type: 'fill',
        ...withOsmBucket('highway_area', 15, b, f(['==', ['get', 'surface'], surface])),
        paint: {
          'fill-pattern': pattern,
          'fill-opacity': opacity,
        },
      })
    }
  }

  return layers
}

/** Combine optional extra filter (unused helper for future surface rules). */
export function allFilters(...parts: FilterSpecification[]): FilterSpecification {
  return ['all', ...parts] as FilterSpecification
}
