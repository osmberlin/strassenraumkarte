/**
 * QGIS draw order + OSM `layer` stacking for MapLibre.
 *
 * QGIS legend: top of tree = drawn last (on top). MapLibre: first layer in the
 * style array = drawn first (bottom). `CORE_PAINT_ORDER` is bottom → top.
 *
 * ## G0.2 decision — OSM `layer` buckets
 *
 * QGIS clones highway / markings / barriers into six filtered copies
 * (`layer >= 3` … `layer <= -2`). A single MapLibre layer with `sort-key` on
 * `["get","layer"]` cannot interleave *across* style layers (e.g. markings on
 * `layer=1` must sit above highway fill on `layer=0` but below highway on
 * `layer=1`).
 *
 * **Choice:** emit one style-layer set per OSM bucket (faithful, verbose) for
 * any source-layer that participates in the ×7 stack. Use `osmLayerFilter(bucket)`
 * on each copy. Non-stacked layers (landuse, water, buildings, trees, labels)
 * stay single.
 *
 * Within each bucket, paint order matches the QGIS highway subgroup:
 * path → service → tactile → highway_area (+ blur) → road markings → separation.
 */
import type { ExpressionSpecification, FilterSpecification } from '@maplibre/maplibre-gl-style-spec'

/** Source-layer ids that follow the QGIS ×7 OSM `layer` stack. */
export const OSM_STACKED_SOURCE_LAYERS = [
  'highway_path',
  'highway_service',
  'tactile_paving',
  'highway_area',
  'road_marking_polygon',
  'road_marking_way',
  'road_marking_node',
  'separation',
] as const

export type OsmStackedSourceLayer = (typeof OSM_STACKED_SOURCE_LAYERS)[number]

export type OsmLayerBucketId = 'lm2' | 'lm1' | 'l0' | 'l1' | 'l2' | 'l3p'

export type OsmLayerBucket = {
  /** Stable id suffix, e.g. `l3p`, `l0`, `lm2`. */
  id: OsmLayerBucketId
  /** QGIS group label. */
  label: string
  /**
   * Draw rank among buckets: lower paints first (under).
   * Matches QGIS tree: `<= -2` at the bottom of the layered group, `>= 3` on top.
   */
  rank: number
}

/**
 * Bottom → top among OSM layer buckets (QGIS `highway (layered)` tree order reversed).
 * `layer = 0 OR IS NULL` is the ground-level default.
 */
export const OSM_LAYER_BUCKETS: readonly OsmLayerBucket[] = [
  { id: 'lm2', label: 'layer <= -2', rank: 0 },
  { id: 'lm1', label: 'layer = -1', rank: 1 },
  { id: 'l0', label: 'layer = 0', rank: 2 },
  { id: 'l1', label: 'layer = 1', rank: 3 },
  { id: 'l2', label: 'layer = 2', rank: 4 },
  { id: 'l3p', label: 'layer >= 3', rank: 5 },
] as const

/** MapLibre filter for one OSM bucket (feature property `layer`). */
export function osmLayerFilter(bucketId: OsmLayerBucketId): FilterSpecification {
  switch (bucketId) {
    case 'lm2':
      return ['<=', ['get', 'layer'], -2]
    case 'lm1':
      return ['==', ['get', 'layer'], -1]
    case 'l0':
      // QGIS: `"layer" = 0 OR "layer" IS NULL`
      return ['any', ['!', ['has', 'layer']], ['==', ['get', 'layer'], 0]]
    case 'l1':
      return ['==', ['get', 'layer'], 1]
    case 'l2':
      return ['==', ['get', 'layer'], 2]
    case 'l3p':
      return ['>=', ['get', 'layer'], 3]
    default: {
      const _exhaustive: never = bucketId
      return _exhaustive
    }
  }
}

/**
 * Core street-space paint stages, bottom → top (MapLibre array order).
 * Matches docs/maplibre-style-groups.md G1→G12 for layers we export today.
 */
export const CORE_PAINT_ORDER = [
  'landuse',
  'water_body_dissolved',
  'waterway_clipped',
  // Within each OSM bucket these are expanded in this relative order:
  'highway_path',
  'highway_service',
  'tactile_paving',
  'highway_area',
  'road_marking_polygon',
  'road_marking_way',
  'road_marking_node',
  'separation',
  'building_shade',
  'building',
  'building_parts_dissolved_height',
  'building_lines',
  'tree',
  'label_waterway',
  'label_highway',
] as const

export type CorePaintSourceLayer = (typeof CORE_PAINT_ORDER)[number]

export function isOsmStacked(sourceLayer: string): sourceLayer is OsmStackedSourceLayer {
  return (OSM_STACKED_SOURCE_LAYERS as readonly string[]).includes(sourceLayer)
}

/** Sort-key expression when a compact single-layer approach is enough (labels, etc.). */
export function osmLayerSortKey(): ExpressionSpecification {
  return ['coalesce', ['get', 'layer'], 0] as ExpressionSpecification
}

/**
 * Style layer id helper: `highway_area-fill-l0`, `landuse-fill`, …
 */
export function styleLayerId(
  sourceLayer: string,
  role: string,
  bucketId?: OsmLayerBucketId,
): string {
  return bucketId ? `${sourceLayer}-${role}-${bucketId}` : `${sourceLayer}-${role}`
}
