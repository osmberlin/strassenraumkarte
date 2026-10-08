/**
 * G3 — Landscape, bridges & railway.
 *
 * Landscape sits in the land group (above water). Bridges and railway are part
 * of the ×7 OSM `layer` stack and paint under highway within each bucket.
 */
import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { layerShadow } from '../effects'
import { base, withOsmBucket } from '../expr'
import { metresToPixels } from '../metres'
import {
  SHAPE_ICON,
  iconSizeFromMetres,
  markerLineLayout,
  shapeIconSizeFromMetres,
  shapeOffset,
} from '../sprite-icons'
import { styleLayerId, type OsmLayerBucketId } from '../order'

const LANDSCAPE_BROWN = '#965220'
/** QGIS layer opacity of `landscape_way`. */
const LANDSCAPE_WAY_OPACITY = 0.5
const BRIDGE_FILL = '#dddddd'
const RAIL_ACTIVE = '#808080'
const RAIL_DISUSED = '#8ea08e'
const RAIL_TIE = '#a8a8a7'
const RAIL_TIE_DISUSED = '#b0b0af'
const SPRING_FILL = '#cac7ed'
const SPRING_OUTLINE = '#a396d9'

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

function clsIn(values: string[]): ExpressionSpecification {
  return ['in', ['get', 'class'], ['literal', values]] as ExpressionSpecification
}

function notTunnel(): ExpressionSpecification {
  return [
    'any',
    ['!', ['has', 'tunnel']],
    ['!=', ['coalesce', ['get', 'tunnel'], ''], 'yes'],
  ] as ExpressionSpecification
}

function isDisusedRail(): ExpressionSpecification {
  return [
    'in',
    ['get', 'railway'],
    ['literal', ['abandoned', 'construction', 'disused']],
  ] as ExpressionSpecification
}

function isActiveRail(): ExpressionSpecification {
  return ['all', notTunnel(), ['!', isDisusedRail()]] as ExpressionSpecification
}

function isDisusedRailOpen(): ExpressionSpecification {
  return ['all', notTunnel(), isDisusedRail()] as ExpressionSpecification
}

/** Half-gauge offset in metres (QGIS: gauge/1000/2 or 0.7175). */
function railHalfOffsetM(): ExpressionSpecification {
  return [
    'case',
    [
      'all',
      ['>', ['coalesce', ['get', 'gauge'], 0], 100],
      ['<', ['coalesce', ['get', 'gauge'], 0], 5000],
    ],
    ['/', ['to-number', ['get', 'gauge']], 2000],
    0.7175,
  ] as ExpressionSpecification
}

function railOffsetPx(sign: 1 | -1): ExpressionSpecification {
  return metresToPixels(['*', railHalfOffsetM(), sign] as ExpressionSpecification)
}

/** HashLine length from gauge (QGIS: gauge/1000+1.1 or 2.5). */
function tieWidthM(): ExpressionSpecification {
  return [
    'case',
    [
      'all',
      ['>', ['coalesce', ['get', 'gauge'], 0], 100],
      ['<', ['coalesce', ['get', 'gauge'], 0], 5000],
    ],
    ['+', ['/', ['to-number', ['get', 'gauge']], 1000], 1.1],
    2.5,
  ] as ExpressionSpecification
}

/** Landscape way/node — after water in the ground stack. */
export function landscapeLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  // Cliff / embankment / earth_bank — brown line + MarkerLine of equilateral triangles
  // (angle 180: apex to the right of the line direction, i.e. downhill). QGIS switches width,
  // interval, marker size and line offset at $length 20 m; `symbol-spacing` is not
  // data-driven, hence two layer pairs. Layer opacity 0.5 is applied per line / tick.
  const landscapeClasses = ['cliff', 'embankment', 'earth_bank'] as const
  const shortFilter = f([
    'all',
    clsIn([...landscapeClasses]),
    ['<', ['coalesce', ['get', 'length'], 0], 20],
  ])
  const longFilter = f([
    'all',
    clsIn([...landscapeClasses]),
    ['>=', ['coalesce', ['get', 'length'], 0], 20],
  ])

  // tickMinz: first zoom at which the interval is ≥ 1 px (`markerLineLayout`).
  for (const [role, filter, widthM, spacingM, tickM, tickMinz] of [
    ['short', shortFilter, 0.3, 1.2, 0.8, 16],
    ['long', longFilter, 0.6, 2.4, 1.6, 15],
  ] as const) {
    layers.push({
      id: `landscape_way-line-${role}`,
      type: 'line',
      ...base('landscape_way', 15, filter),
      layout: { 'line-cap': 'butt', 'line-join': 'bevel' },
      paint: {
        'line-color': LANDSCAPE_BROWN,
        'line-width': metresToPixels(widthM),
        'line-opacity': LANDSCAPE_WAY_OPACITY,
      },
    })
    layers.push({
      id: `landscape_way-ticks-${role}`,
      type: 'symbol',
      ...base('landscape_way', tickMinz, filter),
      layout: {
        ...markerLineLayout(spacingM),
        'icon-image': SHAPE_ICON.landscapeTriangle,
        'icon-size': shapeIconSizeFromMetres(tickM),
        'icon-rotate': 180,
        // MarkerLine offset = line width (0.3 / 0.6 m) to the right = 3/8 of the marker size.
        'icon-offset': [0, -shapeOffset(0.375)],
      },
      paint: { 'icon-opacity': LANDSCAPE_WAY_OPACITY },
    })
  }

  // Peak — QGIS has a placeholder (stock hospital SVG, black α 0.2, 1.5 m); drawn as a
  // brown triangle of that size instead.
  layers.push({
    id: 'landscape_node-peak',
    type: 'symbol',
    ...base('landscape_node', 15, f(['==', ['get', 'class'], 'peak'])),
    layout: {
      'icon-image': SHAPE_ICON.landscapeTriangle,
      'icon-size': shapeIconSizeFromMetres(1.5),
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  })

  // Rock / stone — packed rock01 (QGIS RasterMarker, 1 m wide); rotation from export.
  for (const cls of ['rock', 'stone'] as const) {
    layers.push({
      id: `landscape_node-${cls}`,
      type: 'symbol',
      ...base('landscape_node', 15, f(['==', ['get', 'class'], cls])),
      layout: {
        'icon-image': 'symbols:rock/rock01',
        'icon-size': iconSizeFromMetres(1),
        'icon-rotate': ['coalesce', ['get', 'rotation'], 0],
        'icon-rotation-alignment': 'map',
        'icon-pitch-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-ignore-placement': true,
      },
    })
  }

  // Spring — soft purple circle
  layers.push({
    id: 'landscape_node-spring',
    type: 'circle',
    ...base('landscape_node', 15, f(['==', ['get', 'class'], 'spring'])),
    paint: {
      'circle-color': SPRING_FILL,
      'circle-radius': metresToPixels(1),
      'circle-stroke-color': SPRING_OUTLINE,
      'circle-stroke-width': metresToPixels(0.5),
    },
  })

  return layers
}

/** Bridges + railway for one OSM layer bucket (paint before highway path). */
export function bridgeRailwayLayersForBucket(bucketId: OsmLayerBucketId): LayerSpecification[] {
  const layers: LayerSpecification[] = []
  const b = bucketId

  // bridge_shade — fill + widest layerShadow in the project (blur 5 m)
  const shadeBase = withOsmBucket('bridge_shade', 15, b)
  layers.push(
    layerShadow(styleLayerId('bridge_shade', 'shadow', b), shadeBase, {
      blurMU: 5,
      offsetMU: 0,
      angleDeg: 45,
      color: '#000000',
      opacity: 0.33,
    }),
  )
  layers.push({
    id: styleLayerId('bridge_shade', 'fill', b),
    type: 'fill',
    ...shadeBase,
    paint: {
      'fill-color': BRIDGE_FILL,
      'fill-outline-color': BRIDGE_FILL,
    },
  })

  // bridge — flat grey, no outline
  layers.push({
    id: styleLayerId('bridge', 'fill', b),
    type: 'fill',
    ...withOsmBucket('bridge', 15, b),
    paint: {
      'fill-color': BRIDGE_FILL,
      'fill-outline-color': BRIDGE_FILL,
    },
  })

  // railway ties — HashLine → wide dashed line (same compromise as G4/G5)
  for (const [role, filter, color] of [
    ['tie', isActiveRail(), RAIL_TIE],
    ['tie-disused', isDisusedRailOpen(), RAIL_TIE_DISUSED],
  ] as const) {
    layers.push({
      id: styleLayerId('railway_way', role, b),
      type: 'line',
      ...withOsmBucket('railway_way', 15, b, f(filter)),
      layout: { 'line-cap': 'butt', 'line-join': 'bevel' },
      paint: {
        'line-color': color,
        'line-width': metresToPixels(tieWidthM()),
        // 0.3 m dash / 0.9 m gap at ref width ≈ 2.5 m → [0.12, 0.36]
        'line-dasharray': [0.12, 0.36],
        'line-opacity': 0.9,
      },
    })
  }

  // railway profile — two parallel rails at ±half-gauge
  for (const [role, filter, color] of [
    ['profile', isActiveRail(), RAIL_ACTIVE],
    ['profile-disused', isDisusedRailOpen(), RAIL_DISUSED],
  ] as const) {
    for (const [side, sign] of [
      ['neg', -1],
      ['pos', 1],
    ] as const) {
      layers.push({
        id: styleLayerId('railway_way', `${role}-${side}`, b),
        type: 'line',
        ...withOsmBucket('railway_way', 15, b, f(filter)),
        layout: { 'line-cap': 'butt', 'line-join': 'miter' },
        paint: {
          'line-color': color,
          'line-width': metresToPixels(0.24),
          'line-offset': railOffsetPx(sign),
        },
      })
    }
  }

  // railway_node — buffer_stop / signal as grey squares
  layers.push({
    id: styleLayerId('railway_node', 'buffer-stop', b),
    type: 'circle',
    ...withOsmBucket(
      'railway_node',
      15,
      b,
      f(['==', ['get', 'railway'], 'buffer_stop']),
    ),
    paint: {
      'circle-color': '#939393',
      'circle-radius': metresToPixels(0.8),
    },
  })
  layers.push({
    id: styleLayerId('railway_node', 'signal', b),
    type: 'circle',
    ...withOsmBucket(
      'railway_node',
      15,
      b,
      f(['==', ['get', 'railway'], 'signal']),
    ),
    paint: {
      'circle-color': '#939393',
      'circle-radius': metresToPixels(0.5),
    },
  })

  return layers
}
