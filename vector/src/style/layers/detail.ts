import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { MARKING_DEFAULT, TREE_CROWN, TREE_SHADOW, TREE_TRUNK } from '../colors'
import { metreOffsetTranslate } from '../effects'
import { OSM_LAYER_BUCKETS, styleLayerId, type OsmLayerBucketId } from '../order'
import { base, withOsmBucket } from '../expr'
import { metresToPixels, metresToPixelsFromProp } from '../metres'
import { furnitureLayersForBucket } from './furniture'
import { patternLayers } from './patterns'

/**
 * Distinct `dasharray` metre pairs from PostGIS (`params.sql` + live sample).
 * MapLibre cannot data-drive `line-dasharray`, so each value is its own layer.
 * Values are ground metres (`a;b`); converted to MapLibre units as a/w, b/w
 * with reference width 0.12 m (QGIS default marking width).
 */
const ROAD_MARKING_DASHARRAYS = ['0.5;0.25', '1;1', '3;3', '5;1'] as const

const MARKING_REF_WIDTH_M = 0.12

/** Rasterized SVG size used by `missing-style-images` resolver. */
const ICON_PIXELS = 64

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

function strokeStr(): ExpressionSpecification {
  return ['coalesce', ['get', 'stroke'], ''] as ExpressionSpecification
}

/** QGIS: regexp_match("stroke", 'double|;') */
function isDoubleStroke(): ExpressionSpecification {
  return [
    'any',
    ['in', 'double', strokeStr()],
    ['in', ';', strokeStr()],
  ] as ExpressionSpecification
}

function isSharksTeeth(): ExpressionSpecification {
  return ['==', ['get', 'stroke'], 'sharks_teeth'] as ExpressionSpecification
}

function isZigzagPattern(): ExpressionSpecification {
  return ['==', ['get', 'pattern'], 'zigzag'] as ExpressionSpecification
}

/** Disabled zebra/ladder HashLine (QGIS checkstate=0). */
function isZebraStroke(): ExpressionSpecification {
  return [
    'in',
    ['get', 'stroke'],
    ['literal', ['zebra', 'ladder']],
  ] as ExpressionSpecification
}

function isSingleLine(): ExpressionSpecification {
  return [
    'all',
    ['!', isDoubleStroke()],
    ['!', isSharksTeeth()],
    ['!', isZigzagPattern()],
    ['!', isZebraStroke()],
  ] as ExpressionSpecification
}

function dashIsNull(): ExpressionSpecification {
  // Solid lines: missing / empty dasharray (QGIS uses synthetic `99;0`).
  return [
    'any',
    ['!', ['has', 'dasharray']],
    ['==', ['coalesce', ['get', 'dasharray'], ''], ''],
  ] as ExpressionSpecification
}

function dashEquals(value: string): ExpressionSpecification {
  return ['==', ['get', 'dasharray'], value] as ExpressionSpecification
}

/** Metre dash pair → MapLibre dasharray (multiples of line width). */
function dashToMapLibre(dash: string, refWidthM = MARKING_REF_WIDTH_M): [number, number] {
  const [aRaw, bRaw] = dash.split(';')
  const a = Number(aRaw)
  const b = Number(bRaw ?? aRaw)
  const w = refWidthM > 0 ? refWidthM : MARKING_REF_WIDTH_M
  return [a / w, b / w]
}

function markingColor(): ExpressionSpecification {
  // PostGIS stores CSS colour names (`white`, `yellow`, …); MapLibre accepts them.
  return ['coalesce', ['get', 'colour'], MARKING_DEFAULT] as ExpressionSpecification
}

function surfaceColourFill(): ExpressionSpecification {
  return [
    'match',
    ['coalesce', ['get', 'colour'], ''],
    'green',
    '#00c503',
    ['get', 'colour'],
  ] as ExpressionSpecification
}

function markingWidthPx(): ExpressionSpecification {
  return metresToPixelsFromProp('width', MARKING_REF_WIDTH_M)
}

/** icon-size so a ICON_PIXELS raster covers `metres` on the ground. */
function iconSizeFromMetres(metres: ExpressionSpecification): ExpressionSpecification {
  return metresToPixels(['/', metres, ICON_PIXELS] as ExpressionSpecification)
}

function pushMarkingLine(
  layers: LayerSpecification[],
  bucketId: OsmLayerBucketId,
  role: string,
  extra: ExpressionSpecification,
  opts: {
    join?: 'miter' | 'bevel' | 'round'
    offsetM?: ExpressionSpecification
    dash?: string | null
  } = {},
): void {
  const dashFilter =
    opts.dash == null || opts.dash === ''
      ? dashIsNull()
      : dashEquals(opts.dash)
  layers.push({
    id: styleLayerId('road_marking_way', role, bucketId),
    type: 'line',
    ...withOsmBucket(
      'road_marking_way',
      17,
      bucketId,
      f(['all', extra, dashFilter] as ExpressionSpecification),
    ),
    layout: {
      'line-cap': 'butt',
      'line-join': opts.join ?? 'miter',
    },
    paint: {
      'line-color': markingColor(),
      'line-width': markingWidthPx(),
      ...(opts.offsetM ? { 'line-offset': opts.offsetM } : {}),
      ...(opts.dash ? { 'line-dasharray': dashToMapLibre(opts.dash) } : {}),
    },
  })
}

function doubleOffset(sign: 1 | -1): ExpressionSpecification {
  // QGIS: ± width / 1.25
  return metresToPixels([
    '*',
    ['/', ['coalesce', ['get', 'width'], MARKING_REF_WIDTH_M], 1.25],
    sign,
  ] as ExpressionSpecification)
}

function pushWayDashVariants(
  layers: LayerSpecification[],
  bucketId: OsmLayerBucketId,
  roleBase: string,
  extra: ExpressionSpecification,
  opts: {
    join?: 'miter' | 'bevel' | 'round'
    offsetM?: ExpressionSpecification
  } = {},
): void {
  pushMarkingLine(layers, bucketId, `${roleBase}-solid`, extra, {
    ...opts,
    dash: null,
  })
  for (const dash of ROAD_MARKING_DASHARRAYS) {
    const slug = dash.replace(';', '_')
    pushMarkingLine(layers, bucketId, `${roleBase}-dash-${slug}`, extra, {
      ...opts,
      dash,
    })
  }
}

/**
 * Detail: road markings (per OSM bucket), separation, trees.
 *
 * G5 paints follow QGIS RuleRenderer filters from `style/strassenraumkarte.qgz`.
 */
export function markingFurnitureLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  for (const bucket of OSM_LAYER_BUCKETS) {
    const b = bucket.id

    // --- road_marking_polygon ---
    // Skip zigzag/x (no-render placeholders; geometry lives on road_marking_way).
    // ELSE debug #b7484b intentionally omitted for production preview.

    // restriction / barred_area — stripes (default) + null pattern
    layers.push({
      id: styleLayerId('road_marking_polygon', 'fill-stripes', b),
      type: 'fill',
      ...withOsmBucket(
        'road_marking_polygon',
        17,
        b,
        f([
          'all',
          ['in', ['get', 'road_marking'], ['literal', ['restriction', 'barred_area']]],
          [
            'any',
            ['!', ['has', 'pattern']],
            ['==', ['get', 'pattern'], ''],
            [
              '!',
              [
                'in',
                ['get', 'pattern'],
                ['literal', ['zigzag', 'x', 'crosshatch', 'chessboard', 'none']],
              ],
            ],
          ],
        ]),
      ),
      paint: {
        // LinePatternFill not portable — flat white stand-in (see Known deviations).
        'fill-color': MARKING_DEFAULT,
        'fill-opacity': 0.35,
      },
    })
    layers.push({
      id: styleLayerId('road_marking_polygon', 'outline-stripes', b),
      type: 'line',
      ...withOsmBucket(
        'road_marking_polygon',
        17,
        b,
        f([
          'all',
          ['in', ['get', 'road_marking'], ['literal', ['restriction', 'barred_area']]],
          [
            'any',
            ['!', ['has', 'pattern']],
            ['==', ['get', 'pattern'], ''],
            [
              '!',
              [
                'in',
                ['get', 'pattern'],
                ['literal', ['zigzag', 'x', 'crosshatch', 'chessboard', 'none']],
              ],
            ],
          ],
        ]),
      ),
      paint: {
        'line-color': MARKING_DEFAULT,
        'line-width': metresToPixels(0.12),
      },
    })

    // crosshatch / chessboard — same flat stand-in until PostGIS hatch geometry exists
    for (const pattern of ['crosshatch', 'chessboard'] as const) {
      layers.push({
        id: styleLayerId('road_marking_polygon', `fill-${pattern}`, b),
        type: 'fill',
        ...withOsmBucket(
          'road_marking_polygon',
          17,
          b,
          f([
            'all',
            ['in', ['get', 'road_marking'], ['literal', ['restriction', 'barred_area']]],
            ['==', ['get', 'pattern'], pattern],
          ]),
        ),
        paint: {
          'fill-color': MARKING_DEFAULT,
          'fill-opacity': 0.45,
        },
      })
      layers.push({
        id: styleLayerId('road_marking_polygon', `outline-${pattern}`, b),
        type: 'line',
        ...withOsmBucket(
          'road_marking_polygon',
          17,
          b,
          f([
            'all',
            ['in', ['get', 'road_marking'], ['literal', ['restriction', 'barred_area']]],
            ['==', ['get', 'pattern'], pattern],
          ]),
        ),
        paint: {
          'line-color': MARKING_DEFAULT,
          'line-width': metresToPixels(0.12),
        },
      })
    }

    // pattern=none — outline only
    layers.push({
      id: styleLayerId('road_marking_polygon', 'outline-none', b),
      type: 'line',
      ...withOsmBucket(
        'road_marking_polygon',
        17,
        b,
        f([
          'all',
          ['in', ['get', 'road_marking'], ['literal', ['restriction', 'barred_area']]],
          ['==', ['get', 'pattern'], 'none'],
        ]),
      ),
      paint: {
        'line-color': MARKING_DEFAULT,
        'line-width': metresToPixels(0.12),
      },
    })

    // zebra_stripe — solid fill from colour
    layers.push({
      id: styleLayerId('road_marking_polygon', 'fill-zebra', b),
      type: 'fill',
      ...withOsmBucket(
        'road_marking_polygon',
        17,
        b,
        f(['==', ['get', 'road_marking'], 'zebra_stripe']),
      ),
      paint: {
        'fill-color': markingColor(),
        'fill-opacity': 1,
      },
    })

    // surface_colour / crossing with colour
    layers.push({
      id: styleLayerId('road_marking_polygon', 'fill-surface', b),
      type: 'fill',
      ...withOsmBucket(
        'road_marking_polygon',
        17,
        b,
        f([
          'all',
          ['in', ['get', 'road_marking'], ['literal', ['crossing', 'surface_colour']]],
          ['has', 'colour'],
          ['!', ['in', ['get', 'colour'], ['literal', ['no', 'none', '']]]],
        ]),
      ),
      paint: {
        'fill-color': surfaceColourFill(),
        'fill-opacity': 0.45,
      },
    })

    // --- road_marking_way ---
    // Order: specific strokes first conceptually; MapLibre filters are exclusive.

    // sharks_teeth — MarkerLine triangles @ ~0.75 m → symbol along line (▼ stand-in)
    layers.push({
      id: styleLayerId('road_marking_way', 'sharks-teeth', b),
      type: 'symbol',
      ...withOsmBucket('road_marking_way', 17, b, f(isSharksTeeth())),
      layout: {
        'symbol-placement': 'line',
        'symbol-spacing': metresToPixels(0.75),
        'text-field': '▼',
        'text-size': metresToPixels(0.5),
        'text-allow-overlap': true,
        'text-ignore-placement': true,
        'text-rotation-alignment': 'map',
        'text-pitch-alignment': 'map',
      },
      paint: {
        'text-color': markingColor(),
      },
    })

    // double line — two offsets ± width/1.25
    pushWayDashVariants(layers, b, 'double-pos', isDoubleStroke(), {
      offsetM: doubleOffset(1),
    })
    pushWayDashVariants(layers, b, 'double-neg', isDoubleStroke(), {
      offsetM: doubleOffset(-1),
    })

    // zigzag bevel (pattern=zigzag generated restriction lines)
    pushWayDashVariants(layers, b, 'zigzag', isZigzagPattern(), {
      join: 'bevel',
    })

    // single line (ELSE) — solid + per-dasharray splits
    pushWayDashVariants(layers, b, 'single', isSingleLine(), {
      join: 'miter',
    })

    // --- road_marking_node — SvgMarker via missing-image resolver ---
    layers.push({
      id: styleLayerId('road_marking_node', 'arrow', b),
      type: 'symbol',
      ...withOsmBucket(
        'road_marking_node',
        17,
        b,
        f(['==', ['get', 'road_marking'], 'arrow']),
      ),
      layout: {
        'icon-image': [
          'concat',
          'symbols/traffic_signs/arrows/',
          ['to-string', ['get', 'arrow']],
        ],
        'icon-rotate': ['coalesce', ['get', 'direction'], 0],
        'icon-rotation-alignment': 'map',
        'icon-pitch-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
        // QGIS height = length; width = length * 0.3 * clamp — square icon uses length.
        'icon-size': iconSizeFromMetres([
          'coalesce',
          ['get', 'length'],
          5,
        ] as ExpressionSpecification),
      },
    })

    layers.push({
      id: styleLayerId('road_marking_node', 'traffic-sign', b),
      type: 'symbol',
      ...withOsmBucket(
        'road_marking_node',
        17,
        b,
        f(['==', ['get', 'road_marking'], 'traffic_sign']),
      ),
      layout: {
        'icon-image': [
          'concat',
          'symbols/traffic_signs/',
          ['to-string', ['coalesce', ['get', 'class'], 'DE']],
          '/',
          ['to-string', ['get', 'symbol']],
        ],
        'icon-rotate': ['+', ['coalesce', ['get', 'direction'], 0], 180],
        'icon-rotation-alignment': 'map',
        'icon-pitch-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
        'icon-size': iconSizeFromMetres([
          'coalesce',
          ['get', 'width'],
          ['get', 'length'],
          2,
        ] as ExpressionSpecification),
      },
    })

    layers.push({
      id: styleLayerId('road_marking_node', 'symbol', b),
      type: 'symbol',
      ...withOsmBucket(
        'road_marking_node',
        17,
        b,
        f([
          'all',
          ['==', ['get', 'road_marking'], 'symbol'],
          ['in', ['get', 'symbol'], ['literal', ['bicycle', 'footway', 'wheelchair']]],
        ]),
      ),
      layout: {
        'icon-image': [
          'concat',
          'symbols/traffic_signs/symbols/',
          ['to-string', ['get', 'symbol']],
        ],
        'icon-rotate': ['coalesce', ['get', 'direction'], 0],
        'icon-rotation-alignment': 'map',
        'icon-pitch-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
        'icon-size': iconSizeFromMetres([
          'coalesce',
          ['get', 'width'],
          ['get', 'length'],
          1,
        ] as ExpressionSpecification),
      },
    })

    // --- separation ---
    // bollard / flex_post / vertical_panel: MarkerLine @ 2 m → symbol-placement line
    for (const [kind, color, sizeM] of [
      ['bollard', '#505050', 0.35],
      ['flex_post', '#a0a0a0', 0.3],
      ['vertical_panel', '#505050', 0.35],
    ] as const) {
      layers.push({
        id: styleLayerId('separation', kind, b),
        type: 'symbol',
        ...withOsmBucket(
          'separation',
          17,
          b,
          f(['in', kind, ['coalesce', ['get', 'separation'], '']]),
        ),
        layout: {
          'symbol-placement': 'line',
          'symbol-spacing': metresToPixels(2),
          'text-field': '●',
          'text-size': metresToPixels(sizeM),
          'text-allow-overlap': true,
          'text-ignore-placement': true,
          'text-rotation-alignment': 'map',
        },
        paint: {
          'text-color': color,
          'text-halo-color': '#ededed',
          'text-halo-width': metresToPixels(0.1),
        },
      })
    }

    // bump — HashLine 2 m → along-line dash approximation (same compromise as G4 steps)
    layers.push({
      id: styleLayerId('separation', 'bump', b),
      type: 'line',
      ...withOsmBucket(
        'separation',
        17,
        b,
        f(['in', 'bump', ['coalesce', ['get', 'separation'], '']]),
      ),
      layout: { 'line-cap': 'square', 'line-join': 'bevel' },
      paint: {
        'line-color': '#505050',
        'line-width': metresToPixels(0.25),
        // 0.25 m dash / 1.75 m gap at ref width 0.25 → [1, 7]
        'line-dasharray': [1, 7],
      },
    })

    // G6 furniture & barriers (QGIS: above separation within each OSM bucket)
    layers.push(...furnitureLayersForBucket(b))
  }

  return layers
}

/** Trees — circle crowns (graphics optional later). Shadow then crown then trunk. */
export function treeLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []
  const treeBase = base('tree', 17)
  const shadowTranslate = metreOffsetTranslate(0.4, 45)

  const crownRadius: ExpressionSpecification = [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    17,
    ['*', ['/', ['coalesce', ['get', 'diameter_crown'], 7], 2], metresFactor(17)],
    20,
    ['*', ['/', ['coalesce', ['get', 'diameter_crown'], 7], 2], metresFactor(20)],
  ]

  const trunkRadius: ExpressionSpecification = [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    17,
    ['*', ['/', ['coalesce', ['get', 'circumference'], 1.57], 6.283185], metresFactor(17)],
    20,
    ['*', ['/', ['coalesce', ['get', 'circumference'], 1.57], 6.283185], metresFactor(20)],
  ]

  layers.push({
    id: 'tree-crown-shadow',
    type: 'circle',
    ...treeBase,
    paint: {
      'circle-color': TREE_SHADOW,
      'circle-opacity': 0.35,
      // shrub blur 1.5 m vs tree 3 m → softer / harder circle-blur stand-in
      'circle-blur': [
        'case',
        ['==', ['get', 'natural'], 'shrub'],
        0.4,
        0.6,
      ],
      'circle-radius': crownRadius,
      'circle-translate': shadowTranslate,
    } as never,
  })

  layers.push({
    id: 'tree-trunk-shadow',
    type: 'circle',
    ...treeBase,
    paint: {
      'circle-color': TREE_SHADOW,
      'circle-opacity': 0.07,
      'circle-blur': 0.4,
      'circle-radius': trunkRadius,
      'circle-translate': shadowTranslate,
    } as never,
  })

  layers.push({
    id: 'tree-crown',
    type: 'circle',
    ...treeBase,
    filter: ['!=', ['get', 'natural'], 'tree_stump'],
    paint: {
      'circle-color': TREE_CROWN,
      'circle-opacity': 0.85,
      'circle-blur': 0.35,
      'circle-radius': crownRadius,
    } as never,
  })

  layers.push({
    id: 'tree-trunk',
    type: 'circle',
    ...treeBase,
    paint: {
      'circle-color': TREE_TRUNK,
      'circle-opacity': 0.75,
      'circle-radius': trunkRadius,
    } as never,
  })

  // QGIS trunk labeling: `ref` at 7 pt (only when present).
  layers.push({
    id: 'tree-ref',
    type: 'symbol',
    ...treeBase,
    filter: f([
      'all',
      ['has', 'ref'],
      ['!=', ['to-string', ['get', 'ref']], ''],
    ]),
    layout: {
      'text-field': ['to-string', ['get', 'ref']],
      'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
      'text-size': 10,
      'text-offset': [0, 1.1],
      'text-anchor': 'top',
      'text-optional': true,
      'text-allow-overlap': false,
    },
    paint: {
      'text-color': '#5a5740',
      'text-halo-color': 'rgba(237,237,237,0.9)',
      'text-halo-width': 1,
    },
  })

  return layers
}

/** Markings + furniture + patterns + trees (legacy composition for callers). */
export function detailLayers(): LayerSpecification[] {
  return [...markingFurnitureLayers(), ...patternLayers(), ...treeLayers()]
}

function metresFactor(zoom: number, lat = 52.48): number {
  return 2 ** zoom / (78271.51696 * Math.cos((lat * Math.PI) / 180))
}
