import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { BUILDING_LINES, BUILDING_PARTS_FILL } from '../colors'
import { layerShadow } from '../effects'
import { base } from '../expr'
import { metresToPixels } from '../metres'

/** Mean of the QGIS roof Shapeburst ramp #990003 → #ffffff. */
const ROOF_SHAPE_MEAN = '#cc8081'

/** QGIS enableorderby height ascending — shorter parts under taller. */
const PARTS_SORT_KEY = [
  'coalesce',
  ['get', 'height'],
  0,
] as ExpressionSpecification

/**
 * Buildings: shadows → parts (sorted by height, no outline — as in QGIS) → lines.
 *
 * QGIS has no footprint layer: the pink is `building_parts` at α 0.7 over its own
 * shadow and `building_shade`, which is what gives roofs their darker tone
 * (#ffe9e9 alone would be far too pale).
 *
 * Depth comes from two QGIS dropShadows, both multiplied onto the ground:
 * `building_shade` (height-extruded shade polygons from the ETL, source hidden)
 * and the building parts themselves.
 *
 * `roof shape` (layer blend Screen, opacity 0.404) is a Shapeburst from #990003
 * at the edge to white in the middle for nearly every building. MapLibre has no
 * distance-to-edge fill, so it is screened as one flat mid-ramp colour: right
 * overall tone, no lighter roof centre (gap #8 in docs/maplibre-style-gaps.md).
 */
export function buildingLayers(): LayerSpecification[] {
  const partsBase = base('building_parts_dissolved_height', 15)
  const linesBase = base('building_lines', 15)

  const layers: LayerSpecification[] = []

  layers.push(
    layerShadow('building-shade', base('building_shade', 15), {
      blurMU: 1.6,
      offsetMU: 0.4,
      angleDeg: 40,
      color: '#000000',
      opacity: 0.138,
    }),
    layerShadow('building-parts-shadow', partsBase, {
      blurMU: 2,
      offsetMU: 1,
      angleDeg: 40,
      color: '#232323',
      // effect opacity 0.4 × symbol alpha 0.7
      opacity: 0.28,
    }),
  )

  layers.push({
    id: 'building-parts-fill',
    type: 'fill',
    ...partsBase,
    layout: {
      'fill-sort-key': PARTS_SORT_KEY,
    },
    paint: {
      'fill-color': BUILDING_PARTS_FILL,
      'fill-opacity': 0.7,
    },
  })

  layers.push({
    id: 'building-roof-shape',
    type: 'fill',
    ...base('building', 15),
    paint: {
      'fill-color': ROOF_SHAPE_MEAN,
      'fill-antialias': false,
      'fill-layer-opacity': 0.404,
      'fill-layer-blend': 'screen',
    },
  })

  // footline_covered: solid #cacaca 0.2 m under a dashed #808080 0.1 m (0.45 m on / off).
  const covered = { ...linesBase, filter: ['==', ['get', 'class'], 'footline_covered'] as FilterSpecification }
  layers.push(
    {
      id: 'building-lines-footline_covered-base',
      type: 'line',
      ...covered,
      layout: { 'line-cap': 'square', 'line-join': 'bevel' },
      paint: { 'line-color': '#cacaca', 'line-width': metresToPixels(0.2) },
    },
    {
      id: 'building-lines-footline_covered',
      type: 'line',
      ...covered,
      layout: { 'line-cap': 'butt', 'line-join': 'bevel' },
      paint: {
        'line-color': BUILDING_LINES,
        'line-width': metresToPixels(0.1),
        // dash lengths are in line widths: 0.45 m / 0.1 m
        'line-dasharray': [4.5, 4.5],
      },
    },
  )

  for (const [cls, metres] of [
    ['footline_uncovered', 0.05],
    ['part_outline', 0.02],
    ['roof_edge', 0.04],
    ['roof_ridge', 0.04],
  ] as const) {
    layers.push({
      id: `building-lines-${cls}`,
      type: 'line',
      ...linesBase,
      filter: ['==', ['get', 'class'], cls],
      layout: { 'line-cap': 'square', 'line-join': 'bevel' },
      paint: {
        'line-color': BUILDING_LINES,
        'line-width': metresToPixels(metres),
      },
    })
  }

  return layers
}
