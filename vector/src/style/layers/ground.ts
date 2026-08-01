import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import {
  FOREST_CLASSES,
  SANDPIT_FILL,
  SURFACE_PATTERNS,
  WATER_FILL,
  WATER_INNER,
  WATERWAY_LINE,
} from '../colors'
import { dropShadow, innerShadow, outerGlow } from '../effects'
import {
  base,
  landuseFillMatch,
  pitchFillCase,
  pitchMarkingIcon,
} from '../expr'
import { metresToPixels, metresToPixelsFromProp } from '../metres'

/** Sprite pixel size for packed `pitches/*` icons (`build-sprite.ts`). */
const PITCH_ICON_PIXELS = 64

function f(expr: ExpressionSpecification): FilterSpecification {
  return expr as FilterSpecification
}

/** Push shared surface `fill-pattern` layers for landuse / pitch. */
function pushSurfacePatterns(
  layers: LayerSpecification[],
  idPrefix: string,
  sourceLayer: string,
  minzoom: number,
): void {
  for (const group of SURFACE_PATTERNS) {
    const role = `pattern-${group.pattern.replaceAll('/', '-')}`
    layers.push({
      id: `${idPrefix}-${role}`,
      type: 'fill',
      ...base(
        sourceLayer,
        minzoom,
        f(['in', ['get', 'surface'], ['literal', [...group.surfaces]]]),
      ),
      paint: {
        'fill-pattern': group.pattern,
        'fill-opacity': group.opacity,
      },
    })
  }
}

/** icon-size so a PITCH_ICON_PIXELS raster covers `metres` on the ground. */
function pitchIconSizeFromMetres(metres: ExpressionSpecification): ExpressionSpecification {
  return metresToPixels(['/', metres, PITCH_ICON_PIXELS] as ExpressionSpecification)
}

/**
 * Ground: landuse (+ forest effects, surface textures), pitch (+ markings),
 * sandpit, water body, waterway.
 *
 * Paint order matches QGIS landuse/landcover (bottom → top): landuse → surface →
 * pitch → pitch surface → pitch_markings → sandpit → water.
 */
export function groundLayers(): LayerSpecification[] {
  const landuseBase = base('landuse', 15)
  const pitchBase = base('pitch', 15)
  const sandpitBase = base('sandpit', 15)
  const waterBase = base('water_body_dissolved', 15)
  const forestFilter = [
    'in',
    ['get', 'class'],
    ['literal', [...FOREST_CLASSES]],
  ] as FilterSpecification

  const layers: LayerSpecification[] = []

  layers.push(
    ...dropShadow('landuse-forest', { ...landuseBase, filter: forestFilter }, {
      blurM: 1,
      offsetM: 0.4,
      angleDeg: 40,
      color: '#232323',
      opacity: 0.33,
    }),
  )

  layers.push({
    id: 'landuse-fill',
    type: 'fill',
    ...landuseBase,
    paint: {
      'fill-color': landuseFillMatch(),
      'fill-opacity': 1,
    },
  })

  layers.push(
    ...outerGlow('landuse-forest', { ...landuseBase, filter: forestFilter }, {
      blurM: 0.75,
      color: '#c8dbb6',
      opacityInner: 0.35,
      opacityOuter: 0.2,
    }),
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

  layers.push(
    ...innerShadow('water', waterBase, {
      blurM: 4,
      color: WATER_INNER,
      opacity: 0.55,
    }),
  )

  const waterwayWidth = metresToPixelsFromProp('width', 1.5)

  layers.push({
    id: 'waterway-line',
    type: 'line',
    ...base('waterway_clipped', 15),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': WATERWAY_LINE,
      'line-width': waterwayWidth,
    },
  })

  layers.push({
    id: 'waterway-tunnel',
    type: 'line',
    ...base('waterway_clipped', 15, [
      'any',
      ['==', ['get', 'tunnel'], 'yes'],
      ['==', ['get', 'covered'], 'yes'],
    ]),
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': WATERWAY_LINE,
      'line-opacity': 0.55,
      'line-dasharray': [1, 1.5],
      'line-width': waterwayWidth,
    },
  })

  return layers
}
