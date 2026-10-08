/**
 * G6 — Street furniture & barriers (QGIS highway layered stack, after separation).
 *
 * Prefer circle layers for SimpleMarkers; SvgMarker / RasterMarker use the packed
 * `symbols:…` sprite icons (`../sprite-icons.ts`), sized by their QGIS width in metres. Compound multi-part markers
 * are simplified (see docs Known deviations).
 */
import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { shadowPaint, type LayerShadowOptions } from '../effects'
import { withOsmBucket } from '../expr'
import { metresToPixels } from '../metres'
import {
  SHAPE_ICON,
  iconSizeFromMetres,
  markerLineLayout,
  shapeIconSizeFromMetres,
} from '../sprite-icons'
import { styleLayerId, type OsmLayerBucketId } from '../order'

/** Most furniture stays z17 (tippecanoe). Playground has no QGIS scale gate → z15. */
const MINZ = 17
const PLAYGROUND_MINZ = 15

/** QGIS feature_polygon dropShadows (MapUnits, angle clockwise from north, multiply). */
const SHADOW_FAR: LayerShadowOptions = { blurMU: 2, offsetMU: 1, angleDeg: 45, color: '#000000', opacity: 0.1 }
const SHADOW_NEAR: LayerShadowOptions = { blurMU: 2, offsetMU: 0.5, angleDeg: 45, color: '#000000', opacity: 0.1 }
const SHADOW_PIER: LayerShadowOptions = { blurMU: 1, offsetMU: 0, angleDeg: 45, color: '#232323', opacity: 0.2 }
const POLY_BG_SHADOW: Record<string, LayerShadowOptions> = {
  mast: SHADOW_NEAR,
  pier: SHADOW_PIER,
  shelter: SHADOW_FAR,
}

const PLAYGROUND_FILL = '#d2c8a0'
const PLAYGROUND_OUTLINE = '#b7916e'
/** #d2c8a0 with the QGIS cross-hatch (#b7916e, ~19 % coverage) mixed in. */
const PLAYGROUND_CLIMB = '#cdbe96'

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

function clsEq(value: string): ExpressionSpecification {
  return ['==', ['get', 'class'], value] as ExpressionSpecification
}

function clsIn(values: string[]): ExpressionSpecification {
  return ['in', ['get', 'class'], ['literal', values]] as ExpressionSpecification
}

function barrierEq(value: string): ExpressionSpecification {
  return ['==', ['get', 'barrier'], value] as ExpressionSpecification
}

function barrierIn(values: string[]): ExpressionSpecification {
  return ['in', ['get', 'barrier'], ['literal', values]] as ExpressionSpecification
}

/** QGIS SimpleMarker size is diameter (m) → MapLibre circle radius. */
function circleRadiusM(diameterM: number): ExpressionSpecification {
  return metresToPixels(diameterM / 2)
}

function subclassStr(): ExpressionSpecification {
  return ['to-string', ['coalesce', ['get', 'subclass'], '']] as ExpressionSpecification
}

/** Gate / turnstile fill from QGIS `foot` access expression. */
function accessFillColor(): ExpressionSpecification {
  return [
    'match',
    ['coalesce', ['get', 'foot'], ''],
    ['no', 'private'],
    '#ff0000',
    'yes',
    '#90ee90',
    ['permissive', 'destination', 'customers'],
    '#ffff00',
    '#ffffff',
  ] as ExpressionSpecification
}

function bicycleParkingIcon(): ExpressionSpecification {
  return [
    'case',
    ['==', ['get', 'class'], 'bicycle_rental'],
    'symbols:amenity/bicycle_rental',
    ['==', subclassStr(), 'cargo_bike'],
    'symbols:amenity/cargo_bike',
    ['==', ['get', 'class'], 'small_electric_vehicle_parking'],
    'symbols:amenity/small_electric_vehicle',
    'symbols:amenity/bicycle',
  ] as ExpressionSpecification
}

/** QGIS: `@mercator_scale * if("subclass" = 'cargo_bike', 2.2, 1.8)`. */
function bicycleParkingSizeM(): ExpressionSpecification {
  return ['case', ['==', subclassStr(), 'cargo_bike'], 2.2, 1.8] as ExpressionSpecification
}

function benchIcon(): ExpressionSpecification {
  return [
    'case',
    ['>=', ['index-of', 'backrest_no', subclassStr()], 0],
    'symbols:amenity/bench_backrest_no',
    'symbols:amenity/bench',
  ] as ExpressionSpecification
}

function postBoxIcon(): ExpressionSpecification {
  return [
    'case',
    ['==', subclassStr(), 'PIN Mail'],
    'symbols:amenity/post_box_green',
    'symbols:amenity/post_box_yellow',
  ] as ExpressionSpecification
}

function tableTennisIcon(): ExpressionSpecification {
  return [
    'case',
    ['==', subclassStr(), 'net_no'],
    'symbols:leisure/table_tennis_net_no',
    ['==', subclassStr(), 'net_yes'],
    'symbols:leisure/table_tennis_net_yes',
    'symbols:leisure/table_tennis',
  ] as ExpressionSpecification
}

function mobilityHubIcon(): ExpressionSpecification {
  return [
    'case',
    ['==', subclassStr(), 'Jelbi'],
    'symbols:amenity/mobility_hub_Jelbi',
    'symbols:amenity/mobility_hub',
  ] as ExpressionSpecification
}

function trafficArrowIcon(): ExpressionSpecification {
  return [
    'case',
    ['>=', ['index-of', '222-10', subclassStr()], 0],
    'symbols:traffic_signs/DE/222-10',
    'symbols:traffic_signs/DE/222',
  ] as ExpressionSpecification
}

function trafficPanelIcon(): ExpressionSpecification {
  return [
    'case',
    ['>=', ['index-of', '605-20', subclassStr()], 0],
    'symbols:traffic_signs/DE/605-20',
    ['>=', ['index-of', '605-11', subclassStr()], 0],
    'symbols:traffic_signs/DE/605-11',
    ['>=', ['index-of', '605-21', subclassStr()], 0],
    'symbols:traffic_signs/DE/605-21',
    'symbols:traffic_signs/DE/605-10',
  ] as ExpressionSpecification
}

function pushCircle(
  layers: LayerSpecification[],
  sourceLayer: string,
  role: string,
  bucketId: OsmLayerBucketId,
  filter: FilterSpecification,
  opts: {
    color: string | ExpressionSpecification
    diameterM: number
    opacity?: number
    stroke?: string
    strokeWidthM?: number
    minzoom?: number
  },
): void {
  layers.push({
    id: styleLayerId(sourceLayer, role, bucketId),
    type: 'circle',
    ...withOsmBucket(sourceLayer, opts.minzoom ?? MINZ, bucketId, filter),
    paint: {
      'circle-color': opts.color,
      'circle-opacity': opts.opacity ?? 1,
      'circle-radius': circleRadiusM(opts.diameterM),
      ...(opts.stroke
        ? {
            'circle-stroke-color': opts.stroke,
            'circle-stroke-width': metresToPixels(opts.strokeWidthM ?? 0.06),
          }
        : {}),
    },
  })
}

function pushIcon(
  layers: LayerSpecification[],
  sourceLayer: string,
  role: string,
  bucketId: OsmLayerBucketId,
  filter: FilterSpecification,
  opts: {
    icon: string | ExpressionSpecification
    sizeM: number | ExpressionSpecification
    rotate?: ExpressionSpecification
    opacity?: number
  },
): void {
  layers.push({
    id: styleLayerId(sourceLayer, role, bucketId),
    type: 'symbol',
    ...withOsmBucket(sourceLayer, MINZ, bucketId, filter),
    layout: {
      'icon-image': opts.icon,
      'icon-size': iconSizeFromMetres(opts.sizeM),
      'icon-rotate': opts.rotate ?? 0,
      'icon-rotation-alignment': 'map',
      'icon-pitch-alignment': 'map',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
    paint: {
      ...(opts.opacity != null ? { 'icon-opacity': opts.opacity } : {}),
    },
  })
}

function pushFill(
  layers: LayerSpecification[],
  sourceLayer: string,
  role: string,
  bucketId: OsmLayerBucketId,
  filter: FilterSpecification,
  opts: {
    color: string
    opacity?: number
    outline?: string
    outlineWidthM?: number
    minzoom?: number
    /** QGIS dropShadow of the symbol layer. */
    shadow?: LayerShadowOptions
  },
): void {
  const z = opts.minzoom ?? MINZ
  layers.push({
    id: styleLayerId(sourceLayer, role, bucketId),
    type: 'fill',
    ...withOsmBucket(sourceLayer, z, bucketId, filter),
    paint: {
      'fill-color': opts.color,
      'fill-opacity': opts.opacity ?? 1,
      ...(opts.shadow ? shadowPaint(opts.shadow) : {}),
      // No `fill-outline-color`: it is always a full-strength 1 px line, far heavier than the
      // QGIS outline (a few cm on the ground). The metre-width line layer below is the outline.
    },
  })
  if (opts.outline && (opts.outlineWidthM ?? 0) > 0) {
    layers.push({
      id: styleLayerId(sourceLayer, `${role}-outline`, bucketId),
      type: 'line',
      ...withOsmBucket(sourceLayer, z, bucketId, filter),
      paint: {
        'line-color': opts.outline,
        'line-width': metresToPixels(opts.outlineWidthM ?? 0.1),
      },
    })
  }
}

function pushLine(
  layers: LayerSpecification[],
  sourceLayer: string,
  role: string,
  bucketId: OsmLayerBucketId,
  filter: FilterSpecification,
  opts: {
    color: string
    widthM: number
    opacity?: number
    dash?: [number, number]
    minzoom?: number
  },
): void {
  layers.push({
    id: styleLayerId(sourceLayer, role, bucketId),
    type: 'line',
    ...withOsmBucket(sourceLayer, opts.minzoom ?? MINZ, bucketId, filter),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': opts.color,
      'line-width': metresToPixels(opts.widthM),
      'line-opacity': opts.opacity ?? 1,
      ...(opts.dash ? { 'line-dasharray': opts.dash } : {}),
    },
  })
}

/** QGIS MarkerLine: one packed `symbols:shapes/*` icon every `spacingM` along the line. */
function pushMarkerLine(
  layers: LayerSpecification[],
  sourceLayer: string,
  role: string,
  bucketId: OsmLayerBucketId,
  filter: FilterSpecification,
  opts: { icon: string; sizeM: number; spacingM: number },
): void {
  layers.push({
    id: styleLayerId(sourceLayer, role, bucketId),
    type: 'symbol',
    ...withOsmBucket(sourceLayer, MINZ, bucketId, filter),
    layout: {
      ...markerLineLayout(opts.spacingM),
      'icon-image': opts.icon,
      'icon-size': shapeIconSizeFromMetres(opts.sizeM),
    },
  })
}

/**
 * QGIS MarkerLine of touching round markers (interval ≈ diameter), too dense for symbols:
 * a zero-length dash with round caps is a dot of the line width. `line-dasharray` counts in
 * line widths, so the gap is interval / diameter and the ground spacing holds at every zoom.
 * The dots are not perfect circles and deform at vertices — use `pushMarkerLine` for sparse
 * rows where that shows.
 */
function pushDotLine(
  layers: LayerSpecification[],
  sourceLayer: string,
  role: string,
  bucketId: OsmLayerBucketId,
  filter: FilterSpecification,
  opts: { color: string | ExpressionSpecification; diameterM: number; spacingM: number },
): void {
  layers.push({
    id: styleLayerId(sourceLayer, role, bucketId),
    type: 'line',
    ...withOsmBucket(sourceLayer, MINZ, bucketId, filter),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': opts.color,
      'line-width': metresToPixels(opts.diameterM),
      'line-dasharray': [0, opts.spacingM / opts.diameterM],
    },
  })
}

/** Paint order: background → barriers → playground → middleground → nodes (QGIS tree reversed). */
export function furnitureLayersForBucket(bucketId: OsmLayerBucketId): LayerSpecification[] {
  const layers: LayerSpecification[] = []
  const b = bucketId

  // --- feature_polygon (background) ---
  const polyBg: [string, string, number?, string?, number?][] = [
    ['artwork', '#dbdbdb', 1, '#808080', 0.1],
    ['clock', '#63d9c6', 1, '#232323', 0.06],
    ['information', '#dbdbdb', 1, '#808080', 0.1],
    ['manhole', '#63d9c6', 0.5, '#505050', 0.06],
    ['mast', '#808080', 0.5, '#808080', 0.2],
    ['monitoring_station', '#63d9c6', 1, '#505050', 0.06],
    ['pier', '#dddddd', 1],
    ['planter', '#c7d6b8', 1, '#505050', 0.06],
    ['public_bookcase', '#b7916e', 0.5, '#b7916e', 0.06],
    ['shelter', '#dadada', 1, '#808080', 0.02],
    ['street_cabinet', '#63d9c6', 1, '#505050', 0.06],
  ]
  for (const [c, color, opacity, outline, ow] of polyBg) {
    pushFill(layers, 'feature_polygon', `bg-${c}`, b, clsEq(c), {
      color,
      opacity,
      outline,
      outlineWidthM: ow,
      shadow: POLY_BG_SHADOW[c],
    })
  }
  pushFill(
    layers,
    'feature_polygon',
    'bg-bench',
    b,
    clsEq('bench'),
    { color: '#bababa', outline: '#808080', outlineWidthM: 0.3 },
  )
  pushFill(
    layers,
    'feature_polygon',
    'bg-bike-parking',
    b,
    clsIn(['bicycle_parking', 'bicycle_rental', 'small_electric_vehicle_parking']),
    { color: '#bfbecf', opacity: 0.67 },
  )
  pushFill(
    layers,
    'feature_polygon',
    'bg-fountain',
    b,
    clsEq('fountain'),
    { color: '#cac7ed', outline: '#a396d9', outlineWidthM: 0.1 },
  )
  pushFill(
    layers,
    'feature_polygon',
    'bg-mobility-hub',
    b,
    clsEq('mobility_hub'),
    { color: '#bfbecf', opacity: 0.67 },
  )
  pushLine(
    layers,
    'feature_polygon',
    'bg-mobility-hub-ring',
    b,
    clsEq('mobility_hub'),
    { color: '#f0d722', widthM: 0.5, opacity: 0.5 },
  )
  pushFill(
    layers,
    'feature_polygon',
    'bg-parklet',
    b,
    clsEq('parklet'),
    { color: '#d2c8a0', outline: '#e4b389', outlineWidthM: 0.6 },
  )
  // Centroid icons on background polygons
  pushIcon(
    layers,
    'feature_polygon',
    'bg-bike-icon',
    b,
    clsIn(['bicycle_parking', 'bicycle_rental', 'small_electric_vehicle_parking']),
    { icon: bicycleParkingIcon(), sizeM: bicycleParkingSizeM(), opacity: 1 },
  )
  pushIcon(
    layers,
    'feature_polygon',
    'bg-fountain-icon',
    b,
    clsEq('fountain'),
    { icon: 'symbols:amenity/fountain', sizeM: 3.2 },
  )
  pushIcon(
    layers,
    'feature_polygon',
    'bg-mobility-hub-icon',
    b,
    clsEq('mobility_hub'),
    { icon: mobilityHubIcon(), sizeM: 2.2 },
  )

  // --- feature_way (background): pier ---
  pushLine(layers, 'feature_way', 'bg-pier', b, clsEq('pier'), {
    color: '#85b66f',
    widthM: 0.26,
  })

  // --- barrier_polygon ---
  pushFill(
    layers,
    'barrier_polygon',
    'hedge',
    b,
    barrierIn(['hedge', 'fence;hedge', 'hedge;fence']),
    { color: '#c7d6b8' },
  )
  pushFill(layers, 'barrier_polygon', 'planter', b, barrierEq('planter'), {
    color: '#c7d6b8',
    outline: '#505050',
    outlineWidthM: 0.06,
  })
  pushFill(layers, 'barrier_polygon', 'wall', b, barrierEq('wall'), {
    color: '#c0c0c0',
    outline: '#505050',
    outlineWidthM: 0.1,
  })

  // --- barrier_way ---
  pushLine(layers, 'barrier_way', 'hedge', b, barrierEq('hedge'), {
    color: '#a7cd9d',
    widthM: 0.5,
  })
  for (const [kind, color, w] of [
    ['fence;hedge', '#a7cd9d', 0.5],
    ['hedge;fence', '#a7cd9d', 0.5],
  ] as const) {
    pushLine(layers, 'barrier_way', `${kind}-green`, b, barrierEq(kind), {
      color,
      widthM: w,
    })
    pushLine(layers, 'barrier_way', `${kind}-fence`, b, barrierEq(kind), {
      color: '#505050',
      widthM: 0.1,
    })
  }
  pushLine(layers, 'barrier_way', 'fence', b, barrierEq('fence'), {
    color: '#505050',
    widthM: 0.1,
  })
  pushLine(layers, 'barrier_way', 'wall', b, barrierIn(['wall', 'retaining_wall']), {
    color: '#505050',
    widthM: 0.1,
  })
  pushLine(layers, 'barrier_way', 'kerb', b, barrierEq('kerb'), {
    color: '#7e7e7e',
    widthM: 0.15,
  })
  pushLine(layers, 'barrier_way', 'handrail', b, barrierEq('handrail'), {
    color: '#505050',
    widthM: 0.08,
  })
  pushLine(
    layers,
    'barrier_way',
    'thin',
    b,
    barrierIn(['gate', 'guard_rail', 'railing', 'chain', 'yes']),
    { color: '#505050', widthM: 0.1 },
  )
  pushLine(layers, 'barrier_way', 'ditch', b, barrierEq('ditch'), {
    color: '#d6d8ed',
    widthM: 0.6,
  })
  // barrier_board: grey / white / red stacked
  pushLine(layers, 'barrier_way', 'board-base', b, barrierEq('barrier_board'), {
    color: '#505050',
    widthM: 0.35,
  })
  pushLine(layers, 'barrier_way', 'board-white', b, barrierEq('barrier_board'), {
    color: '#ffffff',
    widthM: 0.2,
  })
  pushLine(layers, 'barrier_way', 'board-red', b, barrierEq('barrier_board'), {
    color: '#ff0004',
    widthM: 0.2,
    dash: [2, 2],
  })
  // bollard: circle 0.4 m, color 80,80,80, interval 1.5 m.
  pushMarkerLine(layers, 'barrier_way', 'bollard', b, barrierEq('bollard'), {
    icon: SHAPE_ICON.bollard,
    sizeM: 0.4,
    spacingM: 1.5,
  })
  // palisade: circle 0.2 m every 0.2 m; fill #909090 below 1 m height, else #505050
  // (`height` is not in the barrier_way export yet → always the else branch).
  pushDotLine(layers, 'barrier_way', 'palisade', b, barrierEq('palisade'), {
    color: [
      'case',
      ['<', ['to-number', ['coalesce', ['get', 'height'], 99], 99], 1],
      '#909090',
      '#505050',
    ] as ExpressionSpecification,
    diameterM: 0.2,
    spacingM: 0.2,
  })

  // --- playground (QGIS: no scale gate → archive minzoom) ---
  pushLine(layers, 'playground_way', 'casing', b, f(['has', 'playground']), {
    color: PLAYGROUND_OUTLINE,
    widthM: 0.5,
    minzoom: PLAYGROUND_MINZ,
  })
  pushLine(layers, 'playground_way', 'fill', b, f(['has', 'playground']), {
    color: PLAYGROUND_FILL,
    widthM: 0.36,
    minzoom: PLAYGROUND_MINZ,
  })
  pushFill(
    layers,
    'playground_polygon',
    'climbingframe',
    b,
    f(['==', ['get', 'playground'], 'climbingframe']),
    // QGIS: the default fill plus a 45°/135° cross-hatch (#b7916e α 0.2, 0.24 m lines every
    // 0.48 m). That is ~2.6 px per period at z18 — drawn as the resulting flat tint.
    { color: PLAYGROUND_CLIMB, outline: PLAYGROUND_OUTLINE, outlineWidthM: 0.12, minzoom: PLAYGROUND_MINZ },
  )
  pushFill(
    layers,
    'playground_polygon',
    'default',
    b,
    f(['!=', ['get', 'playground'], 'climbingframe']),
    { color: PLAYGROUND_FILL, outline: PLAYGROUND_OUTLINE, outlineWidthM: 0.12, minzoom: PLAYGROUND_MINZ },
  )
  pushCircle(layers, 'playground_node', 'dot', b, f(['has', 'playground']), {
    color: PLAYGROUND_FILL,
    diameterM: 0.75,
    stroke: PLAYGROUND_OUTLINE,
    strokeWidthM: 0.12,
    minzoom: PLAYGROUND_MINZ,
  })

  // --- feature_polygon (middleground) ---
  pushFill(layers, 'feature_polygon', 'mid-chimney', b, clsEq('chimney'), {
    color: '#505050',
    opacity: 0.5,
    shadow: SHADOW_NEAR,
    outline: '#505050',
    outlineWidthM: 0.2,
  })
  pushFill(
    layers,
    'feature_polygon',
    'mid-skatepark',
    b,
    clsEq('skatepark_obstacle'),
    { color: '#abaea7', outline: '#93958f', outlineWidthM: 0.12 },
  )
  pushFill(
    layers,
    'feature_polygon',
    'mid-recycling',
    b,
    f([
      'all',
      clsEq('recycling'),
      ['<', ['coalesce', ['get', 'area'], 0], 150],
    ]),
    { color: '#dadada', outline: '#808080', outlineWidthM: 0.02, shadow: SHADOW_FAR },
  )
  pushIcon(
    layers,
    'feature_polygon',
    'mid-recycling-icon',
    b,
    f([
      'all',
      clsEq('recycling'),
      ['<', ['coalesce', ['get', 'area'], 0], 150],
    ]),
    { icon: 'symbols:amenity/recycling_container', sizeM: 2 },
  )
  pushFill(layers, 'feature_polygon', 'mid-toilets', b, clsEq('toilets'), {
    color: '#cbcbcb',
    shadow: SHADOW_FAR,
    outline: '#808080',
    outlineWidthM: 0.05,
  })
  pushIcon(layers, 'feature_polygon', 'mid-toilets-icon', b, clsEq('toilets'), {
    icon: 'symbols:amenity/toilets',
    sizeM: 1.6,
  })
  pushFill(
    layers,
    'feature_polygon',
    'mid-waste-disposal',
    b,
    clsEq('waste_disposal'),
    { color: '#dadada', outline: '#808080', outlineWidthM: 0.02, shadow: SHADOW_FAR },
  )
  pushIcon(
    layers,
    'feature_polygon',
    'mid-waste-disposal-icon',
    b,
    clsEq('waste_disposal'),
    { icon: 'symbols:amenity/recycling_container', sizeM: 2 },
  )

  // --- feature_way (middleground) ---
  const wayMid: [string, string, number][] = [
    ['artwork', '#85b66f', 0.26],
    ['lock_gate', '#808080', 1.4],
    ['planter', '#dede32', 0.26],
    ['pole', '#5d8cc8', 0.26],
    ['street_lamp', '#d73aab', 0.26],
  ]
  for (const [c, color, w] of wayMid) {
    pushLine(layers, 'feature_way', `mid-${c}`, b, clsEq(c), { color, widthM: w })
  }
  pushLine(layers, 'feature_way', 'mid-bench', b, clsEq('bench'), {
    color: '#808080',
    widthM: 0.3,
  })
  pushLine(
    layers,
    'feature_way',
    'mid-skatepark',
    b,
    clsEq('skatepark_obstacle'),
    { color: '#abaea7', widthM: 0.5 },
  )

  // --- feature_node (middleground) — prioritize circles; SVG for key classes ---
  // Circles / FontMarkers
  pushCircle(layers, 'feature_node', 'advertising-column', b, clsEq('advertising_column'), {
    color: '#d0d0c5',
    diameterM: 1.6,
    stroke: '#505050',
    strokeWidthM: 0.12,
  })
  pushCircle(
    layers,
    'feature_node',
    'bike-parking-pad',
    b,
    clsIn(['bicycle_parking', 'bicycle_rental', 'small_electric_vehicle_parking']),
    { color: '#bfbecf', diameterM: 1.5, opacity: 0.67 },
  )
  pushCircle(layers, 'feature_node', 'charging-station', b, clsEq('charging_station'), {
    color: '#74b0d9',
    diameterM: 0.5,
    stroke: '#505050',
    strokeWidthM: 0.05,
  })
  pushCircle(layers, 'feature_node', 'chimney', b, clsEq('chimney'), {
    color: '#505050',
    diameterM: 1.25,
    opacity: 0.5,
    stroke: '#505050',
    strokeWidthM: 0.12,
  })
  pushCircle(
    layers,
    'feature_node',
    'clock',
    b,
    f([
      'all',
      clsEq('clock'),
      [
        'any',
        ['!', ['has', 'support']],
        ['!', ['in', ['get', 'support'], ['literal', ['wall', 'wall_mounted']]]],
      ],
    ]),
    { color: '#63d9c6', diameterM: 0.6, stroke: '#232323', strokeWidthM: 0.06 },
  )
  pushCircle(layers, 'feature_node', 'drinking-water', b, clsEq('drinking_water'), {
    color: '#d6d8ed',
    diameterM: 0.6,
    stroke: '#505050',
    strokeWidthM: 0.06,
  })
  // fire_hydrant: red ring + H
  pushCircle(layers, 'feature_node', 'fire-hydrant-ring', b, clsEq('fire_hydrant'), {
    color: 'rgba(0,0,0,0)',
    diameterM: 0.7,
    stroke: '#ff0000',
    strokeWidthM: 0.2,
  })
  layers.push({
    id: styleLayerId('feature_node', 'fire-hydrant-h', b),
    type: 'symbol',
    ...withOsmBucket('feature_node', MINZ, b, f(clsEq('fire_hydrant'))),
    layout: {
      'text-field': 'H',
      'text-size': metresToPixels(0.7),
      'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
      'text-allow-overlap': true,
      'text-ignore-placement': true,
    },
    paint: { 'text-color': '#ff0000' },
  })
  pushCircle(layers, 'feature_node', 'flagpole', b, clsEq('flagpole'), {
    color: '#808080',
    diameterM: 0.3,
  })
  pushCircle(layers, 'feature_node', 'fountain-pad', b, clsEq('fountain'), {
    color: '#cac7ed',
    diameterM: 3.2,
    stroke: '#505050',
    strokeWidthM: 0.12,
  })
  pushCircle(layers, 'feature_node', 'grit-bin', b, clsEq('grit_bin'), {
    color: '#e9a95f',
    diameterM: 1,
    stroke: '#8b8579',
    strokeWidthM: 0.2,
  })
  pushCircle(layers, 'feature_node', 'monitoring-station', b, clsEq('monitoring_station'), {
    color: '#808080',
    diameterM: 0.3,
  })
  pushCircle(
    layers,
    'feature_node',
    'parking-tickets',
    b,
    f([
      'all',
      clsEq('vending_machine'),
      ['==', subclassStr(), 'parking_tickets'],
    ]),
    { color: '#63d9c6', diameterM: 0.5, stroke: '#808080', strokeWidthM: 0.04 },
  )
  pushCircle(layers, 'feature_node', 'planter', b, clsEq('planter'), {
    color: '#c7d6b8',
    diameterM: 0.75,
    stroke: '#505050',
    strokeWidthM: 0.12,
  })
  pushCircle(layers, 'feature_node', 'pole', b, clsEq('pole'), {
    color: '#808080',
    diameterM: 0.5,
  })
  pushCircle(layers, 'feature_node', 'shelter', b, clsEq('shelter'), {
    color: '#dadada',
    diameterM: 3,
    stroke: '#505050',
    strokeWidthM: 0.12,
  })
  pushCircle(layers, 'feature_node', 'street-cabinet', b, clsEq('street_cabinet'), {
    color: '#63d9c6',
    diameterM: 0.8,
    stroke: '#808080',
    strokeWidthM: 0.05,
  })
  // street_lamp — simplified single grey circle (drop compound red head / bent mast)
  pushCircle(
    layers,
    'feature_node',
    'street-lamp',
    b,
    clsEq('street_lamp'),
    { color: '#dadada', diameterM: 0.67, stroke: '#808080', strokeWidthM: 0.11 },
  )
  pushCircle(
    layers,
    'feature_node',
    'traffic-sign-pole',
    b,
    f([
      'all',
      clsEq('traffic_sign'),
      ['!', ['>=', ['index-of', '222', subclassStr()], 0]],
      ['!', ['>=', ['index-of', '605', subclassStr()], 0]],
      ['!', ['>=', ['index-of', 'street_name_sign', subclassStr()], 0]],
    ]),
    { color: '#ededed', diameterM: 0.67, opacity: 0.5, stroke: '#808080', strokeWidthM: 0.11 },
  )
  pushCircle(layers, 'feature_node', 'vending-machine', b, clsEq('vending_machine'), {
    color: '#63d9c6',
    diameterM: 0.3,
    stroke: '#808080',
    strokeWidthM: 0.04,
  })
  pushCircle(layers, 'feature_node', 'water-well', b, clsEq('water_well'), {
    color: '#808080',
    diameterM: 1.25,
  })

  // SVG / raster icons (resolver)
  pushIcon(layers, 'feature_node', 'artwork', b, clsEq('artwork'), {
    icon: 'symbols:tourism/artwork',
    sizeM: 1.6,
    opacity: 0.67,
  })
  pushIcon(layers, 'feature_node', 'bench', b, clsEq('bench'), {
    icon: benchIcon(),
    sizeM: 1.7,
    rotate: ['coalesce', ['get', 'direction'], 0] as ExpressionSpecification,
  })
  pushIcon(
    layers,
    'feature_node',
    'bike-icon',
    b,
    clsIn(['bicycle_parking', 'bicycle_rental', 'small_electric_vehicle_parking']),
    { icon: bicycleParkingIcon(), sizeM: bicycleParkingSizeM() },
  )
  pushIcon(layers, 'feature_node', 'fountain-icon', b, clsEq('fountain'), {
    icon: 'symbols:amenity/fountain',
    sizeM: 3.2,
  })
  pushIcon(
    layers,
    'feature_node',
    'guidepost',
    b,
    f(['all', clsEq('information'), ['==', subclassStr(), 'guidepost']]),
    { icon: 'symbols:tourism/guidepost', sizeM: 1.8 },
  )
  pushIcon(layers, 'feature_node', 'loading-ramp', b, clsEq('loading_ramp'), {
    icon: 'symbols:amenity/loading_ramp',
    sizeM: 2.5,
  })
  pushIcon(layers, 'feature_node', 'manhole', b, clsEq('manhole'), {
    icon: 'symbols:man_made/manhole',
    sizeM: 0.75,
    opacity: 0.5,
  })
  pushIcon(
    layers,
    'feature_node',
    'picnic-table',
    b,
    clsIn(['picnic_table', 'table']),
    { icon: 'symbols:leisure/picnic_table', sizeM: 1.75 },
  )
  pushIcon(layers, 'feature_node', 'post-box', b, clsEq('post_box'), {
    icon: postBoxIcon(),
    sizeM: 1.2,
    opacity: 0.5,
  })
  pushIcon(layers, 'feature_node', 'recycling', b, clsEq('recycling'), {
    icon: 'symbols:amenity/recycling',
    sizeM: 1.4,
  })
  pushIcon(layers, 'feature_node', 'table-tennis', b, clsEq('table_tennis'), {
    icon: tableTennisIcon(),
    sizeM: 1.7,
  })
  pushIcon(layers, 'feature_node', 'telephone', b, clsEq('telephone'), {
    icon: 'symbols:amenity/telephone',
    sizeM: 1.2,
  })
  pushIcon(
    layers,
    'feature_node',
    'traffic-arrow',
    b,
    f(['all', clsEq('traffic_sign'), ['>=', ['index-of', '222', subclassStr()], 0]]),
    {
      icon: trafficArrowIcon(),
      sizeM: 0.9,
      rotate: ['coalesce', ['get', 'direction'], 0] as ExpressionSpecification,
    },
  )
  pushIcon(
    layers,
    'feature_node',
    'traffic-panel',
    b,
    f(['all', clsEq('traffic_sign'), ['>=', ['index-of', '605', subclassStr()], 0]]),
    {
      icon: trafficPanelIcon(),
      sizeM: 0.4,
      rotate: ['coalesce', ['get', 'direction'], 0] as ExpressionSpecification,
    },
  )
  pushIcon(
    layers,
    'feature_node',
    'street-name-sign',
    b,
    f([
      'all',
      clsEq('traffic_sign'),
      ['>=', ['index-of', 'street_name_sign', subclassStr()], 0],
    ]),
    {
      icon: 'symbols:traffic_signs/street_name_sign',
      sizeM: 1.4,
      rotate: ['coalesce', ['get', 'direction'], 0] as ExpressionSpecification,
    },
  )
  pushIcon(layers, 'feature_node', 'waste-basket', b, clsEq('waste_basket'), {
    icon: 'symbols:amenity/waste_basket',
    sizeM: 0.8,
  })

  // --- barrier_node ---
  pushCircle(layers, 'barrier_node', 'bollard', b, barrierEq('bollard'), {
    color: '#505050',
    diameterM: 0.4,
  })
  pushCircle(layers, 'barrier_node', 'collision', b, barrierEq('collision_protection'), {
    color: '#808080',
    diameterM: 0.24,
  })
  pushCircle(layers, 'barrier_node', 'entrance', b, barrierEq('entrance'), {
    color: '#e6e2bc',
    diameterM: 1.25,
    stroke: '#a8a8a7',
    strokeWidthM: 0.1,
  })
  pushCircle(layers, 'barrier_node', 'planter', b, barrierIn(['planter', 'flowerpot']), {
    color: '#c7d6b8',
    diameterM: 0.75,
    stroke: '#505050',
    strokeWidthM: 0.06,
  })
  pushCircle(layers, 'barrier_node', 'artwork', b, barrierEq('artwork'), {
    color: '#505050',
    diameterM: 0.6,
  })
  pushCircle(layers, 'barrier_node', 'chain', b, barrierEq('chain'), {
    color: 'rgba(0,0,0,0)',
    diameterM: 1.5,
    stroke: '#505050',
    strokeWidthM: 0.12,
  })
  // Gates / turnstiles — access-coloured fill
  pushCircle(
    layers,
    'barrier_node',
    'gate',
    b,
    barrierIn([
      'gate',
      'bump_gate',
      'kissing_gate',
      'lift_gate',
      'sliding_gate',
      'swing_gate',
      'turnstile',
      'full-height_turnstile',
    ]),
    {
      color: accessFillColor(),
      diameterM: 0.75,
      stroke: '#232323',
      strokeWidthM: 0.1,
    },
  )
  pushCircle(layers, 'barrier_node', 'cycle-barrier', b, barrierEq('cycle_barrier'), {
    color: 'rgba(0,0,0,0)',
    diameterM: 2,
    stroke: '#232323',
    strokeWidthM: 0.12,
  })
  pushIcon(layers, 'barrier_node', 'rock', b, barrierIn(['rock', 'block']), {
    icon: 'symbols:rock/rock01',
    sizeM: 0.6,
    opacity: 0.67,
  })

  return layers
}
