/**
 * QGIS-faithful MapLibre layers for the core street-space group (w4c).
 * Paint order: ground → streets (OSM buckets) → buildings → detail → labels.
 */
import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { buildingLayers } from './layers/buildings'
import { detailLayers } from './layers/detail'
import { foregroundLayers } from './layers/foreground'
import { groundLayers } from './layers/ground'
import { labelLayers } from './layers/labels'
import { streetLayers } from './layers/streets'

export function qgisLayerSpecs(): LayerSpecification[] {
  return [
    ...groundLayers(),
    ...streetLayers(),
    ...buildingLayers(),
    ...detailLayers(),
    // G11 — above buildings / trees (QGIS: entrance + feature foreground)
    ...foregroundLayers(),
    ...labelLayers(),
  ]
}
