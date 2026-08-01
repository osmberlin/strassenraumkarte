/**
 * Shared MapLibre expression helpers for QGIS-faithful paints.
 */
import type { ExpressionSpecification, FilterSpecification } from '@maplibre/maplibre-gl-style-spec'

import { LANDUSE_FILL } from './colors'
import { SOURCE_ID } from './source'
import type { OsmLayerBucketId } from './order'
import { osmLayerFilter } from './order'

export { SOURCE_ID }

export type LayerBase = {
  source: string
  'source-layer': string
  minzoom?: number
  maxzoom?: number
  filter?: FilterSpecification
}

export function base(
  sourceLayer: string,
  minzoom: number,
  filter?: FilterSpecification,
): LayerBase {
  return {
    source: SOURCE_ID,
    'source-layer': sourceLayer,
    minzoom,
    ...(filter ? { filter } : {}),
  }
}

export function withOsmBucket(
  sourceLayer: string,
  minzoom: number,
  bucketId: OsmLayerBucketId,
  extra?: FilterSpecification,
): LayerBase {
  const layerFilter = osmLayerFilter(bucketId)
  const filter = extra ? (['all', layerFilter, extra] as FilterSpecification) : layerFilter
  return base(sourceLayer, minzoom, filter)
}

/** `match` on landuse.class with QGIS fills; unknown → light grey. */
export function landuseFillMatch(): ExpressionSpecification {
  const parts: unknown[] = ['match', ['get', 'class']]
  for (const [cls, color] of Object.entries(LANDUSE_FILL)) {
    parts.push(cls, color)
  }
  parts.push('#e8e8e8')
  return parts as ExpressionSpecification
}

/** highway_area fill from area:highway (sidewalk variant deferred — no footway column). */
export function highwayAreaFillMatch(): ExpressionSpecification {
  return [
    'match',
    ['get', 'area:highway'],
    ['footway', 'path', 'steps', 'bridleway'],
    '#e1e3bd',
    'pedestrian',
    '#d7d8c5',
    'cycleway',
    '#cccccc',
    'service',
    '#cccccc',
    'parking',
    '#a8a8a7',
    'parking_space',
    '#a8a8a7',
    'living_street',
    '#bbbbb2',
    [
      'motorway',
      'trunk',
      'motorway_link',
      'trunk_link',
      'primary',
      'primary_link',
      'secondary',
      'secondary_link',
      'tertiary',
      'tertiary_link',
      'residential',
      'unclassified',
      'road',
      'bus_guideway',
      'bus_bay',
      'turning_circle',
      'turning_loop',
    ],
    '#a8a8a7',
    '#a8a8a7',
  ] as ExpressionSpecification
}

export function coalesceWidth(fallbackM: number): ExpressionSpecification {
  return ['coalesce', ['get', 'width'], fallbackM] as ExpressionSpecification
}
