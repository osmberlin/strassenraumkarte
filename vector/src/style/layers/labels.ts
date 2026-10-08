import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
  SymbolLayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { base } from '../expr'
import { scaleToZoom } from '../metres'

/** Demotiles / OpenMapTiles stack — QGIS uses DejaVu Sans Condensed. */
const LABEL_FONT = ['Open Sans Regular', 'Arial Unicode MS Regular'] as const

/** 10 pt @ 96 DPI ≈ 13 px (paper units — not metresToPixels). */
const LABEL_SIZE_PX = 13

const HAS_NAME = [
  'all',
  ['has', 'name'],
  ['!=', ['to-string', ['get', 'name']], ''],
  ['!', ['has', '_empty_stub']],
] as unknown as FilterSpecification

/** QGIS place rank filters (same on place_node + place_polygon). */
const PLACE_RANKS = {
  /** 1:1000–8000 */
  local: ['city_block', 'farm', 'isolated_dwelling', 'square'],
  /** 1:4000–16000 (archive starts at z15) */
  neighbourhood: ['allotments', 'hamlet', 'islet', 'neighbourhood', 'quarter'],
  // suburb / town / city rules (1:16000 and smaller) lie below the archive minzoom 15.
} as const

function placeFilter(places: readonly string[]): FilterSpecification {
  return [
    'all',
    HAS_NAME,
    ['in', ['get', 'place'], ['literal', [...places]]],
  ] as unknown as FilterSpecification
}

function namedInClasses(classes: readonly string[]): FilterSpecification {
  return [
    'all',
    HAS_NAME,
    ['in', ['get', 'class'], ['literal', [...classes]]],
  ] as unknown as FilterSpecification
}

function zoomField(value: 'high' | 'low'): FilterSpecification {
  return [
    'all',
    HAS_NAME,
    ['==', ['get', 'zoom'], value],
  ] as unknown as FilterSpecification
}

/**
 * QGIS landuse Size DD hides labels when `@map_scale > 6000` and
 * `$area / @map_scale < 25`. MapLibre forbids nested `zoom` in `text-size`,
 * so approximate with a min-area filter below z16.5 (scale≈6000 → 150 000 m²).
 */
function landusePrimaryFilter(minArea?: number): FilterSpecification {
  const classes = namedInClasses(['forest', 'park', 'recreation_ground', 'wood'])
  if (minArea == null) return classes
  return [
    'all',
    classes,
    ['>', ['coalesce', ['get', 'area'], 0], minArea],
  ] as unknown as FilterSpecification
}

/** QGIS label_highway: #dddddd, buffer 2 pt #a8a8a7 α 0.75 — deliberately quiet on the carriageway. */
const HIGHWAY_LABEL_PAINT = {
  'text-color': '#dddddd',
  'text-halo-color': 'rgba(168,168,167,0.75)',
  'text-halo-width': 2,
} as const

const PLACE_PAINT = {
  'text-color': '#d7d8c5',
  'text-halo-color': 'rgba(168,168,167,0.75)',
  'text-halo-width': 1.2,
} as const

function placeSymbolLayers(
  sourceLayer: 'place_node' | 'place_polygon',
): SymbolLayerSpecification[] {
  const isPoly = sourceLayer === 'place_polygon'
  const layoutBase = {
    'text-field': ['coalesce', ['get', 'name'], ''] as ExpressionSpecification,
    'text-font': [...LABEL_FONT],
    'text-size': LABEL_SIZE_PX,
    'text-optional': true,
    'text-allow-overlap': false,
    ...(isPoly
      ? {
          'symbol-placement': 'point' as const,
          'text-max-width': 8,
        }
      : {}),
  }

  const localFilter: FilterSpecification = isPoly
    ? ([
        'all',
        placeFilter(PLACE_RANKS.local),
        [
          '>',
          ['coalesce', ['get', 'area'], 0],
          ['*', 0.75, ['/', 559_082_264, ['^', 2, ['zoom']]]],
        ],
      ] as unknown as FilterSpecification)
    : placeFilter(PLACE_RANKS.local)

  return [
    {
      id: `${sourceLayer}-local`,
      type: 'symbol',
      ...base(sourceLayer, scaleToZoom(8000), localFilter),
      maxzoom: scaleToZoom(1000),
      layout: layoutBase,
      paint: PLACE_PAINT,
    },
    {
      id: `${sourceLayer}-neighbourhood`,
      type: 'symbol',
      ...base(sourceLayer, 15, placeFilter(PLACE_RANKS.neighbourhood)),
      maxzoom: scaleToZoom(4000),
      layout: layoutBase,
      paint: PLACE_PAINT,
    },
  ]
}

/** Labels — housenumbers + G12 symbol layers (line / point / polygon). */
export function labelLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  // QGIS housenumber: addr:housenumber, DejaVu 7.5 pt #b7b7b7, buffer #d8d5d5 α 0.75,
  // visible below 1:1000.
  layers.push({
    id: 'label-housenumber',
    type: 'symbol',
    ...base('housenumber', scaleToZoom(1000)),
    layout: {
      'text-field': ['coalesce', ['get', 'addr:housenumber'], ''],
      'text-font': [...LABEL_FONT],
      // 7.5 pt @ 96 DPI ≈ 10 px
      'text-size': 10,
      'text-optional': true,
      'text-allow-overlap': false,
    },
    paint: {
      'text-color': '#b7b7b7',
      'text-halo-color': 'rgba(216,213,213,0.75)',
      'text-halo-width': 1.5,
    },
  })

  // Landuse names on the landuse fill source-layer (primary + secondary class rules).
  // Primary: forest/park/recreation_ground/wood, 1:2000–64000 → z15–18 (archive clips z13–14).
  const landusePrimaryLayout = {
    'symbol-placement': 'point' as const,
    'text-field': ['coalesce', ['get', 'name'], ''] as ExpressionSpecification,
    'text-font': [...LABEL_FONT],
    'text-size': LABEL_SIZE_PX,
    'text-max-width': 8,
    'text-optional': true,
  }
  const landusePrimaryPaint = {
    'text-color': '#a8a8a7',
    'text-halo-color': 'rgba(225,227,189,0.75)',
    'text-halo-width': 1.2,
  }
  layers.push({
    id: 'label-landuse-primary-far',
    type: 'symbol',
    ...base('landuse', 15, landusePrimaryFilter(150_000)),
    maxzoom: scaleToZoom(6000),
    layout: landusePrimaryLayout,
    paint: landusePrimaryPaint,
  })
  layers.push({
    id: 'label-landuse-primary-near',
    type: 'symbol',
    ...base('landuse', scaleToZoom(6000), landusePrimaryFilter()),
    maxzoom: scaleToZoom(2000),
    layout: landusePrimaryLayout,
    paint: landusePrimaryPaint,
  })

  // Secondary: cemetery/dog_park/farmland/garden/playground, 1:2000–4000 → z17–18, α 0.67.
  layers.push({
    id: 'label-landuse-secondary',
    type: 'symbol',
    ...base(
      'landuse',
      scaleToZoom(4000),
      namedInClasses(['cemetery', 'dog_park', 'farmland', 'garden', 'playground']),
    ),
    maxzoom: scaleToZoom(2000),
    layout: {
      'symbol-placement': 'point',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': [...LABEL_FONT],
      'text-size': LABEL_SIZE_PX,
      'text-max-width': 8,
      'text-optional': true,
    },
    paint: {
      'text-color': '#a8a8a7',
      'text-halo-color': 'rgba(225,227,189,0.75)',
      'text-halo-width': 1.2,
      'text-opacity': 0.67,
    },
  })

  // Water body names — 1:2000–60000 → z15–18.
  layers.push({
    id: 'label-water-body',
    type: 'symbol',
    ...base('label_water_body', 15, HAS_NAME),
    maxzoom: scaleToZoom(2000),
    layout: {
      'symbol-placement': 'point',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': [...LABEL_FONT],
      'text-size': LABEL_SIZE_PX,
      'text-max-width': 8,
      'text-optional': true,
    },
    paint: {
      'text-color': '#aba5d8',
      'text-halo-color': 'rgba(205,203,234,0.75)',
      'text-halo-width': 1.2,
    },
  })

  // Curved waterway labels — 1:2000–16000 → z15–18.
  layers.push({
    id: 'label-waterway',
    type: 'symbol',
    ...base('label_waterway', 15, HAS_NAME),
    maxzoom: scaleToZoom(2000),
    layout: {
      'symbol-placement': 'line',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': [...LABEL_FONT],
      'text-size': LABEL_SIZE_PX,
      'text-max-angle': 25,
      'text-keep-upright': true,
    },
    paint: {
      // QGIS: stream/ditch/drain ↔ river/canal swap colour and buffer.
      'text-color': [
        'match',
        ['get', 'waterway'],
        ['stream', 'ditch', 'drain'],
        '#cdcbea',
        '#aba5d8',
      ] as ExpressionSpecification,
      'text-halo-color': [
        'match',
        ['get', 'waterway'],
        ['stream', 'ditch', 'drain'],
        'rgba(171,165,216,0.75)',
        'rgba(205,203,234,0.75)',
      ] as ExpressionSpecification,
      'text-halo-width': 1.2,
    },
  })

  // Street labels: zoom='high' 1:1000–4000, zoom='low' 1:4000–8000.
  layers.push({
    id: 'label-highway-high',
    type: 'symbol',
    ...base('label_highway', scaleToZoom(4000), zoomField('high')),
    maxzoom: scaleToZoom(1000),
    layout: {
      'symbol-placement': 'line',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': [...LABEL_FONT],
      'text-size': LABEL_SIZE_PX,
      'text-max-angle': 25,
      'text-keep-upright': true,
    },
    paint: {
      ...HIGHWAY_LABEL_PAINT,
      // QGIS FontOpacity: scale < 2000 → 50 %, else 100 %.
      'text-opacity': ['step', ['zoom'], 1, scaleToZoom(2000), 0.5] as ExpressionSpecification,
    },
  })

  layers.push({
    id: 'label-highway-low',
    type: 'symbol',
    ...base('label_highway', scaleToZoom(8000), zoomField('low')),
    maxzoom: scaleToZoom(4000),
    layout: {
      'symbol-placement': 'line',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': [...LABEL_FONT],
      'text-size': LABEL_SIZE_PX,
      'text-max-angle': 25,
      'text-keep-upright': true,
    },
    paint: {
      ...HIGHWAY_LABEL_PAINT,
    },
  })

  layers.push(...placeSymbolLayers('place_node'))
  layers.push(...placeSymbolLayers('place_polygon'))

  return layers
}
