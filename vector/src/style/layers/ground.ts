import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import {
  FOREST_CLASSES,
  LANDUSE_CLASS_PATTERNS,
  SANDPIT_FILL,
  SURFACE_PATTERNS,
  WATER_FILL,
  WATER_INNER,
  WATER_SHORE,
  WATERWAY_LINE,
} from '../colors'
import { innerFade, innerGlow, innerShadow, layerShadow, outerGlow } from '../effects'
import {
  base,
  landuseFillMatch,
  pitchFillCase,
  pitchMarkingIcon,
  surfacePatternLayer,
} from '../expr'
import { metresToPixels } from '../metres'
import { landscapeLayers } from './landscape'

/** Sprite pixel size for packed `pitches/*` icons (`build-sprite.ts`). */
const PITCH_ICON_PIXELS = 64

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

/** Shared multiplied surface texture layer for landuse / pitch (QGIS layer blend Multiply). */
function pushSurfacePatterns(
  layers: LayerSpecification[],
  idPrefix: string,
  sourceLayer: string,
  minzoom: number,
): void {
  const { filter, paint } = surfacePatternLayer(SURFACE_PATTERNS)
  layers.push({
    id: `${idPrefix}-pattern`,
    type: 'fill',
    ...base(sourceLayer, minzoom, filter),
    paint,
  })
}

/** icon-size so a PITCH_ICON_PIXELS raster covers `metres` on the ground. */
function pitchIconSizeFromMetres(metres: ExpressionSpecification): ExpressionSpecification {
  return metresToPixels(['/', metres, PITCH_ICON_PIXELS] as ExpressionSpecification)
}

/**
 * Ground: landuse (+ forest effects, surface textures), pitch (+ markings),
 * sandpit, water body (+ shoreline bands), wetland, waterway.
 *
 * Paint order matches QGIS landuse/landcover (bottom → top): landuse → surface →
 * pitch → pitch surface → pitch_markings → sandpit → water → wetland → waterway.
 */
export function groundLayers(): LayerSpecification[] {
  const landuseBase = base('landuse', 15)
  const pitchBase = base('pitch', 15)
  const sandpitBase = base('sandpit', 15)
  const waterBase = base('water_body_dissolved', 15)
  const wetlandBase = base('wetland', 15)
  const forestFilter = [
    'in',
    ['get', 'class'],
    ['literal', [...FOREST_CLASSES]],
  ] as FilterSpecification

  const layers: LayerSpecification[] = []

  layers.push(
    layerShadow('landuse-forest-shadow', { ...landuseBase, filter: forestFilter }, {
      blurMU: 1,
      offsetMU: 0.4,
      angleDeg: 40,
      color: '#232323',
      opacity: 0.33,
    }),
  )

  // outdoor_seating / construction have no SimpleFill in QGIS (pattern-only).
  layers.push({
    id: 'landuse-fill',
    type: 'fill',
    ...landuseBase,
    filter: f([
      '!',
      [
        'in',
        ['get', 'class'],
        ['literal', ['outdoor_seating', 'construction']],
      ],
    ]),
    paint: {
      'fill-color': landuseFillMatch(),
      'fill-opacity': 1,
    },
  })

  // Class textures of the QGIS landuse symbols (grass on lawns and woods, gravel, sand, …).
  const classTextures = surfacePatternLayer(LANDUSE_CLASS_PATTERNS, {
    property: 'class',
    blend: 'normal',
  })
  layers.push({
    id: 'landuse-class-pattern',
    type: 'fill',
    ...base('landuse', 15, classTextures.filter),
    paint: classTextures.paint,
  })

  // QGIS landuse rule swimming_pool: SimpleFill + innerShadow (#a396d9, blur 4 MapUnits, multiply).
  layers.push(
    ...innerShadow(
      'landuse-swimming_pool',
      { ...landuseBase, filter: f(['==', ['get', 'class'], 'swimming_pool']) },
      { blurM: 4, color: WATER_INNER, opacity: 1 },
    ),
  )

  layers.push(
    ...outerGlow('landuse-forest', { ...landuseBase, filter: forestFilter }, {
      blurM: 0.75,
      color: '#c8dbb6',
      opacityInner: 0.35,
      opacityOuter: 0.2,
    }),
  )

  layers.push(
    ...innerGlow(
      'landuse-glacier',
      { ...landuseBase, filter: f(['==', ['get', 'class'], 'glacier']) },
      { blurM: 0.75, color: '#ebe9f2', opacityInner: 0.35, opacityOuter: 0.2 },
    ),
    ...innerGlow(
      'landuse-reef',
      { ...landuseBase, filter: f(['==', ['get', 'class'], 'reef']) },
      { blurM: 0.75, color: '#d5d2f2', opacityInner: 0.35, opacityOuter: 0.2 },
    ),
  )

  // landuse surface — RasterFill overlay when surface IS NOT NULL (19 categories).
  pushSurfacePatterns(layers, 'landuse-surface', 'landuse', 15)

  // pitch fill CASE
  layers.push({
    id: 'pitch-fill',
    type: 'fill',
    ...pitchBase,
    paint: {
      'fill-color': pitchFillCase(),
      'fill-opacity': 1,
    },
  })

  // pitch surface — same 19-entry texture table
  pushSurfacePatterns(layers, 'pitch-surface', 'pitch', 15)

  // pitch_markings — sprite symbol; uniform scale on dist_long (no independent aspect-fit).
  layers.push({
    id: 'pitch-markings',
    type: 'symbol',
    ...base('pitch_markings', 15),
    layout: {
      'icon-image': pitchMarkingIcon(),
      'icon-rotate': ['+', ['coalesce', ['get', 'direction'], 0], 90],
      'icon-rotation-alignment': 'map',
      'icon-pitch-alignment': 'map',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
      'icon-size': pitchIconSizeFromMetres([
        '*',
        0.95,
        ['coalesce', ['get', 'dist_long'], 20],
      ] as ExpressionSpecification),
    },
  })

  // sandpit — SimpleFill + sand texture + renderer-level innerShadow
  layers.push({
    id: 'sandpit-fill',
    type: 'fill',
    ...sandpitBase,
    paint: {
      'fill-color': SANDPIT_FILL,
      'fill-opacity': 1,
    },
  })

  layers.push({
    id: 'sandpit-pattern',
    type: 'fill',
    ...sandpitBase,
    paint: {
      'fill-pattern': 'sand',
      'fill-opacity': 0.08,
    },
  })

  layers.push(
    ...innerShadow('sandpit', sandpitBase, {
      blurM: 1,
      color: '#000000',
      opacity: 0.2,
    }),
  )

  layers.push({
    id: 'water-fill',
    type: 'fill',
    ...waterBase,
    paint: {
      'fill-color': WATER_FILL,
      'fill-opacity': 1,
    },
  })

  // QGIS stacks three symbol layers that each carry the same innerShadow
  // (#a396d9, blur 4 MapUnits, multiply) — the edge shade multiplies up three times.
  for (const n of [1, 2, 3]) {
    layers.push(
      ...innerShadow(`water-${n}`, waterBase, { blurM: 4, color: WATER_INNER, opacity: 1 }),
    )
  }

  // Shapeburst shoreline: white α 0.2 at the bank fading inward. QGIS scales the
  // distance per feature (1.5–20 m by area); a layer blur is one value → mid-size pond.
  layers.push(
    innerFade('water-shore', waterBase, {
      color: '#ffffff',
      opacity: 0.4, // inner-edge peaks at half strength on a straight bank
      blurMU: 6,
      mode: 'inner-edge',
    }),
  )

  layers.push({
    id: 'water-pattern',
    type: 'fill',
    ...waterBase,
    paint: { 'fill-pattern': 'water', 'fill-opacity': 0.2 },
  })

  // `water body (depth effect)`: whole-shape Shapeburst to #0000cd, layer opacity 0.15.
  layers.push(
    innerFade('water-depth', waterBase, {
      color: '#0000cd',
      layerOpacity: 0.15,
      blurMU: 12,
      mode: 'inner-core',
    }),
  )

  // wetland — RasterFill wetland.png α 0.3 (no base fill in QGIS).
  layers.push({
    id: 'wetland-pattern',
    type: 'fill',
    ...wetlandBase,
    paint: {
      'fill-pattern': 'wetland',
      'fill-opacity': 0.3,
    },
  })

  // Width from "width", else river/canal 12 m, stream/ditch/drain 1.5 m.
  const waterwayWidthM = [
    'coalesce',
    ['get', 'width'],
    [
      'match',
      ['get', 'waterway'],
      'river',
      12,
      'canal',
      12,
      'stream',
      1.5,
      'ditch',
      1.5,
      'drain',
      1.5,
      1.5,
    ],
  ] as ExpressionSpecification
  const waterwayWidth = metresToPixels(waterwayWidthM)

  const waterwayTunnel = f([
    'any',
    ['==', ['get', 'tunnel'], 'yes'],
    ['==', ['get', 'covered'], 'yes'],
  ])
  const waterwayOpen = f([
    'all',
    ['!', ['==', ['get', 'tunnel'], 'yes']],
    ['!', ['==', ['get', 'covered'], 'yes']],
  ])

  layers.push({
    id: 'waterway-line',
    type: 'line',
    ...base('waterway_clipped', 15, waterwayOpen),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': WATERWAY_LINE,
      'line-width': waterwayWidth,
    },
  })

  layers.push({
    id: 'waterway-tunnel',
    type: 'line',
    ...base('waterway_clipped', 15, waterwayTunnel),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': WATERWAY_LINE,
      'line-opacity': 0.55,
      'line-dasharray': [1, 1.5],
      'line-width': waterwayWidth,
    },
  })

  // G3 landscape (QGIS land group, above water)
  layers.push(...landscapeLayers())

  return layers
}
