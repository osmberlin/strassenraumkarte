import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
  SymbolLayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { base } from '../expr'

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
  /** 1:1000–8000 → z16–19 */
  local: ['city_block', 'farm', 'isolated_dwelling', 'square'],
  /** 1:4000–16000 → z15–17 */
  neighbourhood: ['allotments', 'hamlet', 'islet', 'neighbourhood', 'quarter'],
  /** 1:16000–64000 → z13–15 (archive clips below z15) */
  suburb: ['island', 'suburb', 'village'],
  /** 1:32000–64000 → z13–14 (below archive minzoom — kept for completeness) */
  town: ['borough', 'town'],
  /** 1:64000–128000 → z12–13 (below archive minzoom) */
  city: ['city'],
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
      ...base(sourceLayer, 16, localFilter),
      maxzoom: 19,
      layout: layoutBase,
      paint: PLACE_PAINT,
    },
    {
      id: `${sourceLayer}-neighbourhood`,
      type: 'symbol',
      ...base(sourceLayer, 15, placeFilter(PLACE_RANKS.neighbourhood)),
      maxzoom: 17,
      layout: layoutBase,
      paint: PLACE_PAINT,
    },
    {
      id: `${sourceLayer}-suburb`,
      type: 'symbol',
      ...base(sourceLayer, 15, placeFilter(PLACE_RANKS.suburb)),
      maxzoom: 15.5,
      layout: layoutBase,
      paint: PLACE_PAINT,
    },
    {
      id: `${sourceLayer}-town`,
      type: 'symbol',
      ...base(sourceLayer, 13, placeFilter(PLACE_RANKS.town)),
      maxzoom: 14.5,
      layout: layoutBase,
      paint: PLACE_PAINT,
    },
    {
      id: `${sourceLayer}-city`,
      type: 'symbol',
      ...base(sourceLayer, 12, placeFilter(PLACE_RANKS.city)),
      maxzoom: 13.5,
      layout: layoutBase,
      paint: PLACE_PAINT,
    },
  ]
}

/** Labels — housenumbers + G12 symbol layers (line / point / polygon). */
export function labelLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  // QGIS housenumber: addr:housenumber, DejaVu 7.5 pt #b7b7b7, buffer #d8d5d5 α 0.75,
  // visible above ~1:1000 → MapLibre minzoom 18 (overzoom from tippecanoe z17).
  layers.push({
    id: 'label-housenumber',
    type: 'symbol',
    ...base('housenumber', 18),
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
    maxzoom: 16.5,
    layout: landusePrimaryLayout,
    paint: landusePrimaryPaint,
  })
  layers.push({
    id: 'label-landuse-primary-near',
    type: 'symbol',
    ...base('landuse', 16.5, landusePrimaryFilter()),
    maxzoom: 18,
    layout: landusePrimaryLayout,
    paint: landusePrimaryPaint,
  })

  // Secondary: cemetery/dog_park/farmland/garden/playground, 1:2000–4000 → z17–18, α 0.67.
  layers.push({
    id: 'label-landuse-secondary',
    type: 'symbol',
    ...base(
      'landuse',
      17,
      namedInClasses(['cemetery', 'dog_park', 'farmland', 'garden', 'playground']),
    ),
    maxzoom: 18,
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
    maxzoom: 18,
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
    maxzoom: 18,
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

  // Street labels: zoom='high' 1:1000–4000 → z17–19; zoom='low' 1:4000–8000 → z16–17.
  layers.push({
    id: 'label-highway-high',
    type: 'symbol',
    ...base('label_highway', 17, zoomField('high')),
    maxzoom: 19,
    layout: {
      'symbol-placement': 'line',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': [...LABEL_FONT],
      'text-size': LABEL_SIZE_PX,
      'text-max-angle': 25,
      'text-keep-upright': true,
    },
    paint: {
      'text-color': '#dddddd',
      'text-halo-color': 'rgba(168,168,167,0.75)',
      'text-halo-width': 1.2,
      // QGIS FontOpacity: scale < 2000 → 50%, else 100% (≈ z > 18).
      'text-opacity': [
        'interpolate',
        ['linear'],
        ['zoom'],
        17,
        1,
        18,
        1,
        18.1,
        0.5,
      ] as ExpressionSpecification,
    },
  })

  layers.push({
    id: 'label-highway-low',
    type: 'symbol',
    ...base('label_highway', 16, zoomField('low')),
    maxzoom: 17,
    layout: {
      'symbol-placement': 'line',
      'text-field': ['coalesce', ['get', 'name'], ''],
      'text-font': [...LABEL_FONT],
      'text-size': LABEL_SIZE_PX,
      'text-max-angle': 25,
      'text-keep-upright': true,
    },
    paint: {
      'text-color': '#dddddd',
      'text-halo-color': 'rgba(168,168,167,0.75)',
      'text-halo-width': 1.2,
      'text-opacity': 1,
    },
  })

  layers.push(...placeSymbolLayers('place_node'))
  layers.push(...placeSymbolLayers('place_polygon'))

  return layers
}
