import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { MARKING_DEFAULT, TREE_SHADOW, TREE_TRUNK } from '../colors'
import { metreOffsetTranslate } from '../effects'
import { OSM_LAYER_BUCKETS, styleLayerId, type OsmLayerBucketId } from '../order'
import { base, withOsmBucket } from '../expr'
import { metresToPixels, metresToPixelsFromProp } from '../metres'
import { TREE_ICON, iconSizeFromMetres, markingIconSuffix } from '../sprite-icons'
import { furnitureLayersForBucket } from './furniture'
import { patternLayers } from './patterns'

/**
 * Distinct `dasharray` metre pairs from PostGIS (`params.sql` + live sample), `a;b` in
 * ground metres. QGIS draws them as fixed ground lengths; MapLibre measures
 * `line-dasharray` in line widths, so each pair is divided by the feature's width
 * (data-driven `match` over the widths that occur — see `markingDashArray`).
 */
const ROAD_MARKING_DASHARRAYS = ['0.5;0.25', '1;1', '3;3', '5;1'] as const

/** Marking widths (m) present in the data; anything else falls back to the reference width. */
const ROAD_MARKING_WIDTHS_M = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.5] as const

/** QGIS layer opacity of `road_marking_way` (lines of one layer barely overlap → per feature). */
const ROAD_MARKING_WAY_OPACITY = 0.67

const MARKING_REF_WIDTH_M = 0.12

/** QGIS road markings / separation have no scale gate — match archive minzoom. */
const MARKING_MINZ = 15

/** QGIS layer opacity of `road_marking_node` (icons never overlap, so per-icon is equal). */
const ROAD_MARKING_NODE_OPACITY = 0.67

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

function dashIsSet(): ExpressionSpecification {
  return ['in', ['get', 'dasharray'], ['literal', [...ROAD_MARKING_DASHARRAYS]]] as ExpressionSpecification
}

/** Metre dash pair → MapLibre dasharray (multiples of line width). */
function dashToMapLibre(dash: string, widthM: number): [number, number] {
  const [aRaw, bRaw] = dash.split(';')
  const a = Number(aRaw)
  const b = Number(bRaw ?? aRaw)
  return [a / widthM, b / widthM]
}

/** Per-feature dash array so dashes keep their ground length whatever the line width. */
function markingDashArray(): ExpressionSpecification {
  const byDash: unknown[] = ['match', ['get', 'dasharray']]
  for (const dash of ROAD_MARKING_DASHARRAYS) {
    // `match` labels must be integers → key on the width in centimetres.
    const byWidth: unknown[] = [
      'match',
      ['round', ['*', ['coalesce', ['get', 'width'], MARKING_REF_WIDTH_M], 100]],
    ]
    for (const w of ROAD_MARKING_WIDTHS_M) {
      byWidth.push(Math.round(w * 100), ['literal', dashToMapLibre(dash, w)])
    }
    byWidth.push(['literal', dashToMapLibre(dash, MARKING_REF_WIDTH_M)])
    byDash.push(dash, byWidth)
  }
  byDash.push(['literal', [1, 0]])
  return byDash as ExpressionSpecification
}

function markingColor(): ExpressionSpecification {
  // PostGIS stores CSS colour names (`white`, `yellow`, …); MapLibre accepts them.
  return ['coalesce', ['get', 'colour'], MARKING_DEFAULT] as ExpressionSpecification
}

function surfaceColourFill(): ExpressionSpecification {
  // QGIS: CASE WHEN colour = 'green' THEN '#00c503' ELSE colour END.
  // Map named CSS colours to hex so red bike lanes stay vivid in MapLibre.
  return [
    'match',
    ['downcase', ['to-string', ['coalesce', ['get', 'colour'], '']]],
    'green',
    '#00c503',
    'red',
    '#e31a1c',
    'yellow',
    '#ffd52b',
    'blue',
    '#1f78b4',
    'orange',
    '#ff7f00',
    'white',
    '#ffffff',
    ['get', 'colour'],
  ] as ExpressionSpecification
}

/** road_marking_node traffic sign: QGIS marker width = "width" (m). */
function roadSignWidthM(): ExpressionSpecification {
  return ['coalesce', ['get', 'width'], ['get', 'length'], 2] as ExpressionSpecification
}

function markingWidthPx(): ExpressionSpecification {
  return metresToPixelsFromProp('width', MARKING_REF_WIDTH_M)
}

function pushMarkingLine(
  layers: LayerSpecification[],
  bucketId: OsmLayerBucketId,
  role: string,
  extra: ExpressionSpecification,
  opts: {
    join?: 'miter' | 'bevel' | 'round'
    offsetM?: ExpressionSpecification
    dashed: boolean
  },
): void {
  layers.push({
    id: styleLayerId('road_marking_way', role, bucketId),
    type: 'line',
    ...withOsmBucket(
      'road_marking_way',
      MARKING_MINZ,
      bucketId,
      f(['all', extra, opts.dashed ? dashIsSet() : dashIsNull()] as ExpressionSpecification),
    ),
    layout: {
      'line-cap': 'butt',
      'line-join': opts.join ?? 'miter',
    },
    paint: {
      'line-color': markingColor(),
      'line-opacity': ROAD_MARKING_WAY_OPACITY,
      'line-width': markingWidthPx(),
      ...(opts.offsetM ? { 'line-offset': opts.offsetM } : {}),
      ...(opts.dashed ? { 'line-dasharray': markingDashArray() } : {}),
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
  pushMarkingLine(layers, bucketId, `${roleBase}-solid`, extra, { ...opts, dashed: false })
  pushMarkingLine(layers, bucketId, `${roleBase}-dashed`, extra, { ...opts, dashed: true })
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
        MARKING_MINZ,
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
        MARKING_MINZ,
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
        MARKING_MINZ,
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
        MARKING_MINZ,
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
        MARKING_MINZ,
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
        MARKING_MINZ,
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
        MARKING_MINZ,
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
        // QGIS surface-colour symbol alpha is 0.45 for all colours.
        'fill-opacity': 0.45,
      },
    })

    // --- road_marking_way ---
    // Order: specific strokes first conceptually; MapLibre filters are exclusive.

    // sharks_teeth — MarkerLine triangles @ ~0.75 m → symbol along line (▼ stand-in)
    layers.push({
      id: styleLayerId('road_marking_way', 'sharks-teeth', b),
      type: 'symbol',
      ...withOsmBucket(
        'road_marking_way',
        MARKING_MINZ, b, f(isSharksTeeth())),
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

    // --- road_marking_node — SvgMarker: packed `symbols:` icons, runtime resolver for signs ---
    layers.push({
      id: styleLayerId('road_marking_node', 'arrow', b),
      type: 'symbol',
      ...withOsmBucket(
        'road_marking_node',
        MARKING_MINZ,
        b,
        f(['==', ['get', 'road_marking'], 'arrow']),
      ),
      layout: {
        // QGIS fill = "colour" (white, or yellow for temporary markings).
        'icon-image': [
          'concat',
          'symbols:traffic_signs/arrows/',
          ['to-string', ['get', 'arrow']],
          markingIconSuffix(),
        ],
        'icon-rotate': ['coalesce', ['get', 'direction'], 0],
        'icon-rotation-alignment': 'map',
        'icon-pitch-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
        // QGIS: height = length, width = length * 0.3 * max(1, min(2, 2 - length / 5)).
        // The SVGs are 150×500 (0.3), so width = 0.3 * length reproduces the height; the
        // extra widening of arrows shorter than 5 m is not reproduced (uniform icon-size).
        'icon-size': iconSizeFromMetres([
          '*',
          ['coalesce', ['get', 'length'], 5],
          0.3,
        ] as ExpressionSpecification),
      },
      paint: { 'icon-opacity': ROAD_MARKING_NODE_OPACITY },
    })

    layers.push({
      id: styleLayerId('road_marking_node', 'traffic-sign', b),
      type: 'symbol',
      ...withOsmBucket(
        'road_marking_node',
        MARKING_MINZ,
        b,
        f(['==', ['get', 'road_marking'], 'traffic_sign']),
      ),
      layout: {
        // Open-ended sign catalogue → runtime resolver (`symbols/…`, slash). QGIS sets
        // width = "width" and height = "length" independently (signs are painted stretched
        // along the lane); the `#<height/width>` suffix asks the resolver for that stretch.
        'icon-image': [
          'concat',
          'symbols/traffic_signs/',
          ['to-string', ['coalesce', ['get', 'class'], 'DE']],
          '/',
          ['to-string', ['get', 'symbol']],
          '#',
          [
            'to-string',
            ['/', ['coalesce', ['get', 'length'], ['get', 'width'], 2], roadSignWidthM()],
          ],
        ],
        'icon-rotate': ['+', ['coalesce', ['get', 'direction'], 0], 180],
        'icon-rotation-alignment': 'map',
        'icon-pitch-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
        'icon-size': iconSizeFromMetres(roadSignWidthM()),
      },
      paint: { 'icon-opacity': ROAD_MARKING_NODE_OPACITY },
    })

    layers.push({
      id: styleLayerId('road_marking_node', 'symbol', b),
      type: 'symbol',
      ...withOsmBucket(
        'road_marking_node',
        MARKING_MINZ,
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
          'symbols:traffic_signs/symbols/',
          ['to-string', ['get', 'symbol']],
          markingIconSuffix(),
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
      paint: { 'icon-opacity': ROAD_MARKING_NODE_OPACITY },
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
        MARKING_MINZ,
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
        MARKING_MINZ,
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

/**
 * Trees. QGIS layer "tree crown" (categorized on `natural`, layer opacity 0.25):
 * - tree:  RasterMarker `symbols/trees/<needleleaved|broadleaved>.png`, width =
 *   `@mercator_scale * diameter_crown`, angle = "rotation", dropShadow (black, opacity 0.4,
 *   multiply, blur 3 map units, offset 0.4 @ 45°)
 * - shrub: broadleaved.png, size = `@mercator_scale * diameter_crown`, same shadow, blur 1.5
 * `tree_stump` has no category (trunk only). Layer "trunk" draws on top at opacity 0.75.
 *
 * The 0.25 is `symbol-layer-opacity` (local MapLibre patch, docs/maplibre-patches.md).
 * The crown dropShadow is baked into the sprite (`shadow` in sprite-icons.ts), so inside the
 * flattened layer every crown shades the crowns drawn before it, as in QGIS. Its blur is a
 * fixed fraction of the crown instead of 3 map units, and the 0.4 offset is dropped.
 */
export function treeLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []
  const treeBase = base('tree', 17)
  const shadowTranslate = metreOffsetTranslate(0.4, 45)
  const hasCrown = f(['in', ['get', 'natural'], ['literal', ['tree', 'shrub']]])
  const crownDiameterM = ['coalesce', ['get', 'diameter_crown'], 7] as ExpressionSpecification

  const crownRadius: ExpressionSpecification = [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    17,
    ['*', ['/', crownDiameterM, 2], metresFactor(17)],
    20,
    ['*', ['/', crownDiameterM, 2], metresFactor(20)],
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
    type: 'symbol',
    ...treeBase,
    filter: hasCrown,
    layout: {
      // `leaf_type` is exported from the next pipeline run on; older tiles → broadleaved.
      'icon-image': [
        'case',
        [
          'all',
          ['==', ['get', 'natural'], 'tree'],
          ['==', ['get', 'leaf_type'], 'needleleaved'],
        ],
        TREE_ICON.needleleaved,
        TREE_ICON.broadleaved,
      ],
      'icon-size': iconSizeFromMetres(crownDiameterM),
      'icon-rotate': ['coalesce', ['get', 'rotation'], 0],
      'icon-rotation-alignment': 'map',
      'icon-pitch-alignment': 'map',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
    paint: {
      // QGIS layer opacity: crowns are flattened first, so overlaps do not darken.
      'symbol-layer-opacity': 0.25,
    },
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
