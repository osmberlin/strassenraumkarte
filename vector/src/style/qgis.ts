/**
 * QGIS-faithful MapLibre layers for the core street-space group (w4c).
 * Paint order: ground → streets → markingFurniture → patterns → buildings →
 * trees → foreground → labels (matches CORE_PAINT_ORDER: markings before
 * buildings, trees after).
 */
import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { buildingLayers } from './layers/buildings'
import { markingFurnitureLayers, treeLayers } from './layers/detail'
import { foregroundLayers } from './layers/foreground'
import { groundLayers } from './layers/ground'
import { labelLayers } from './layers/labels'
import { patternLayers } from './layers/patterns'
import { streetLayers } from './layers/streets'

export function qgisLayerSpecs(): LayerSpecification[] {
  return [
    ...groundLayers(),
    ...streetLayers(),
    ...markingFurnitureLayers(),
    ...patternLayers(),
    ...buildingLayers(),
    ...treeLayers(),
    // G11 — above buildings / trees (QGIS: entrance + feature foreground)
    ...foregroundLayers(),
    ...labelLayers(),
  ]
}
