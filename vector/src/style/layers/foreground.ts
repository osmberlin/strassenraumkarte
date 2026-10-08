/**
 * G11 — Foreground POI (above buildings in the QGIS tree).
 *
 * `feature_node (foreground) Kopie` is intentional, not a stray duplicate: these
 * classes are absent from middleground (guidepost stays in G6; general information
 * / memorial / toilets / … paint here). `entrance` is a separate top-level layer.
 */
import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { base } from '../expr'
import { metresToPixels } from '../metres'
import { iconSizeFromMetres } from '../sprite-icons'

/** QGIS entrance minScale 3000 ≈ z17.5 */
const ENTRANCE_MINZ = 18
const FG_MINZ = 17

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

function clsEq(value: string): ExpressionSpecification {
  return ['==', ['get', 'class'], value] as ExpressionSpecification
}

function subclassStr(): ExpressionSpecification {
  return ['to-string', ['coalesce', ['get', 'subclass'], '']] as ExpressionSpecification
}

function circleRadiusM(diameterM: number): ExpressionSpecification {
  return metresToPixels(diameterM / 2)
}

export function foregroundLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []

  // --- feature_node (foreground) — deliberate port of "Kopie" ---

  // guard_stone — filled arrowhead → ▶ rotated by direction−90
  layers.push({
    id: 'feature_node-fg-guard-stone',
    type: 'symbol',
    ...base('feature_node', FG_MINZ, f(clsEq('guard_stone'))),
    layout: {
      'text-field': '▶',
      'text-size': metresToPixels(0.5),
      'text-rotate': [
        '-',
        ['coalesce', ['get', 'direction'], 90],
        90,
      ] as ExpressionSpecification,
      'text-rotation-alignment': 'map',
      'text-allow-overlap': true,
      'text-ignore-placement': true,
      'text-font': ['Open Sans Regular', 'Arial Unicode MS Regular'],
    },
    paint: { 'text-color': '#808080' },
  })

  // information (not guidepost — guidepost stays middleground)
  layers.push({
    id: 'feature_node-fg-information',
    type: 'symbol',
    ...base(
      'feature_node',
      FG_MINZ,
      f([
        'all',
        clsEq('information'),
        ['!=', subclassStr(), 'guidepost'],
      ]),
    ),
    layout: {
      'icon-image': 'symbols:tourism/information',
      'icon-size': iconSizeFromMetres(1.2),
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  })

  // mast — grey circle
  layers.push({
    id: 'feature_node-fg-mast',
    type: 'circle',
    ...base('feature_node', FG_MINZ, f(clsEq('mast'))),
    paint: {
      'circle-color': '#808080',
      'circle-radius': circleRadiusM(0.75),
    },
  })

  // memorial (except stolperstein)
  layers.push({
    id: 'feature_node-fg-memorial',
    type: 'symbol',
    ...base(
      'feature_node',
      FG_MINZ,
      f([
        'all',
        clsEq('memorial'),
        ['!=', subclassStr(), 'stolperstein'],
      ]),
    ),
    layout: {
      'icon-image': 'symbols:historic/memorial',
      'icon-size': iconSizeFromMetres(1.2),
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  })

  // public_bookcase — octagon → circle
  layers.push({
    id: 'feature_node-fg-public-bookcase',
    type: 'circle',
    ...base('feature_node', FG_MINZ, f(clsEq('public_bookcase'))),
    paint: {
      'circle-color': '#b7916e',
      'circle-opacity': 0.5,
      'circle-radius': circleRadiusM(1),
      'circle-stroke-color': '#b7916e',
      'circle-stroke-width': metresToPixels(0.06),
    },
  })

  // stolperstein — gold square stand-in (FontMarker ´ omitted)
  layers.push({
    id: 'feature_node-fg-stolperstein',
    type: 'circle',
    ...base(
      'feature_node',
      FG_MINZ,
      f([
        'all',
        clsEq('memorial'),
        ['==', subclassStr(), 'stolperstein'],
      ]),
    ),
    paint: {
      'circle-color': '#c9b46a',
      'circle-opacity': 0.75,
      'circle-radius': circleRadiusM(0.3),
      'circle-stroke-color': '#c9b46a',
      'circle-stroke-width': metresToPixels(0.03),
    },
  })

  // toilets
  layers.push({
    id: 'feature_node-fg-toilets',
    type: 'symbol',
    ...base('feature_node', FG_MINZ, f(clsEq('toilets'))),
    layout: {
      'icon-image': 'symbols:amenity/toilets',
      'icon-size': iconSizeFromMetres(1.6),
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  })

  // viewpoint
  layers.push({
    id: 'feature_node-fg-viewpoint',
    type: 'symbol',
    ...base('feature_node', FG_MINZ, f(clsEq('viewpoint'))),
    layout: {
      'icon-image': [
        'case',
        ['>=', ['index-of', 'all_directions', subclassStr()], 0],
        'symbols:tourism/viewpoint_all_directions',
        'symbols:tourism/viewpoint',
      ] as ExpressionSpecification,
      'icon-size': iconSizeFromMetres([
        'case',
        ['>=', ['index-of', 'all_directions', subclassStr()], 0],
        5.2,
        3,
      ] as ExpressionSpecification),
      'icon-rotate': ['coalesce', ['get', 'direction'], 90] as ExpressionSpecification,
      'icon-rotation-alignment': 'map',
      'icon-pitch-alignment': 'map',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  })

  // --- entrance (minzoom ≈ z18 / QGIS scale 3000) ---

  // parking_entrance
  layers.push({
    id: 'entrance-parking',
    type: 'circle',
    ...base(
      'feature_node',
      ENTRANCE_MINZ,
      f([
        'all',
        clsEq('entrance'),
        ['==', subclassStr(), 'parking_entrance'],
      ]),
    ),
    paint: {
      'circle-color': '#20ecdb',
      'circle-radius': circleRadiusM(0.8),
      'circle-stroke-color': 'rgba(35,0,119,0.5)',
      'circle-stroke-width': metresToPixels(0.2),
    },
  })

  // subway / s-train markers (±1.2 m offset dropped — see Known deviations)
  layers.push({
    id: 'entrance-subway',
    type: 'symbol',
    ...base(
      'feature_node',
      ENTRANCE_MINZ,
      f([
        'all',
        clsEq('entrance'),
        ['>=', ['index-of', 'subway', subclassStr()], 0],
      ]),
    ),
    layout: {
      'icon-image': 'symbols:public_transport/subway',
      'icon-size': iconSizeFromMetres(2),
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  })
  layers.push({
    id: 'entrance-s-train',
    type: 'symbol',
    ...base(
      'feature_node',
      ENTRANCE_MINZ,
      f([
        'all',
        clsEq('entrance'),
        ['>=', ['index-of', 's-train', subclassStr()], 0],
      ]),
    ),
    layout: {
      'icon-image': 'symbols:public_transport/s-train',
      'icon-size': iconSizeFromMetres(2.2),
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  })

  // generic entrance (ELSE — not parking / subway / s-train)
  layers.push({
    id: 'entrance-generic',
    type: 'circle',
    ...base(
      'feature_node',
      ENTRANCE_MINZ,
      f([
        'all',
        clsEq('entrance'),
        ['!=', subclassStr(), 'parking_entrance'],
        ['!', ['>=', ['index-of', 'subway', subclassStr()], 0]],
        ['!', ['>=', ['index-of', 's-train', subclassStr()], 0]],
      ]),
    ),
    paint: {
      'circle-color': '#dad1d1',
      'circle-radius': circleRadiusM(0.6),
      'circle-stroke-color': '#505050',
      'circle-stroke-width': metresToPixels(0.03),
    },
  })

  return layers
}
