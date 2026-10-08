/**
 * Shared MapLibre expression helpers for QGIS-faithful paints.
 */
import type {
  ExpressionSpecification,
  FillLayerSpecification,
  FilterSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { LANDUSE_FILL, TEXTURE_REF_ZOOM, type SurfacePattern } from './colors'
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

/**
 * QGIS `pitch` fill CASE on `surface:colour` / `surface` / `sport`.
 * Colour tags use substring match (`~ 'red'`); surface/sport use exact lists.
 */
export function pitchFillCase(): ExpressionSpecification {
  const colour = ['downcase', ['to-string', ['coalesce', ['get', 'surface:colour'], '']]]
  const surface = ['to-string', ['coalesce', ['get', 'surface'], '']]
  return [
    'case',
    ['>=', ['index-of', 'red', colour], 0],
    '#dbc1b9',
    ['>=', ['index-of', 'green', colour], 0],
    '#b5daa9',
    ['>=', ['index-of', 'blue', colour], 0],
    '#c3c1d7',
    ['>=', ['index-of', 'gray', colour], 0],
    '#c6c9c1',
    ['>=', ['index-of', 'grey', colour], 0],
    '#c6c9c1',
    ['>=', ['index-of', 'yellow', colour], 0],
    '#e3e6c0',
    [
      'in',
      surface,
      [
        'literal',
        [
          'asphalt',
          'compacted',
          'concrete',
          'fine_gravel',
          'gravel',
          'paved',
          'paving_stones',
          'pebblestone',
        ],
      ],
    ],
    '#c6c9c1',
    ['>=', ['index-of', 'grass', surface], 0],
    '#b5daa9',
    ['>=', ['index-of', 'sand', surface], 0],
    '#e3e6c0',
    ['==', ['get', 'sport'], 'table_tennis'],
    '#c6c9c1',
    '#d1d7c6',
  ] as unknown as ExpressionSpecification
}

/**
 * Sprite id for `pitch_markings` (packed `pitches/*` from `bun run sprite`).
 * Mirrors the QGIS SvgMarker path CASE; empty string → no icon.
 */
export function pitchMarkingIcon(): ExpressionSpecification {
  const sport = ['to-string', ['coalesce', ['get', 'sport'], '']]
  const hoops = ['to-string', ['coalesce', ['get', 'hoops'], '']]
  return [
    'case',
    ['>=', ['index-of', 'multi', sport], 0],
    'pitches/multi',
    [
      'all',
      ['>=', ['index-of', 'soccer', sport], 0],
      ['>', ['to-number', ['get', 'dist_long']], 50],
    ],
    'pitches/soccer',
    ['>=', ['index-of', 'soccer', sport], 0],
    'pitches/soccer_small',
    [
      'all',
      [
        'any',
        ['>=', ['index-of', 'basketball', sport], 0],
        ['>=', ['index-of', 'streetball', sport], 0],
      ],
      ['==', hoops, '2'],
    ],
    'pitches/basketball_2',
    [
      'any',
      ['>=', ['index-of', 'basketball', sport], 0],
      ['>=', ['index-of', 'streetball', sport], 0],
    ],
    'pitches/basketball_1',
    [
      'all',
      ['>=', ['index-of', 'tennis', sport], 0],
      ['!', ['>=', ['index-of', 'table_tennis', sport], 0]],
    ],
    'pitches/tennis',
    ['>=', ['index-of', 'volleyball', sport], 0],
    'pitches/volleyball',
    ['>=', ['index-of', 'badminton', sport], 0],
    'pitches/badminton',
    ['>=', ['index-of', 'handball', sport], 0],
    'pitches/handball',
    ['>=', ['index-of', 'field_hockey', sport], 0],
    'pitches/field_hockey',
    ['>=', ['index-of', 'rugby_league', sport], 0],
    'pitches/rugby_league',
    ['>=', ['index-of', 'rugby_union', sport], 0],
    'pitches/rugby_union',
    ['>=', ['index-of', 'chess', sport], 0],
    'pitches/chess',
    '',
  ] as unknown as ExpressionSpecification
}

/**
 * `area:highway` values the QGIS highway_area renderer has a rule for. Everything else
 * (parking_space, traffic_island, platform, …) is not drawn by that layer.
 */
export const HIGHWAY_AREA_CLASSES = [
  'footway', 'path', 'steps', 'bridleway', 'pedestrian', 'cycleway', 'service', 'parking',
  'living_street', 'motorway', 'trunk', 'motorway_link', 'trunk_link', 'primary',
  'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'residential',
  'unclassified', 'road', 'bus_guideway', 'bus_bay', 'turning_circle', 'turning_loop',
] as const

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

export type SurfacePatternLayer = {
  /** Append to the layer id: `pattern` (ground-sized textures) or `pattern-px` (screen-sized). */
  role: 'pattern' | 'pattern-px'
  filter: FilterSpecification
  paint: NonNullable<FillLayerSpecification['paint']>
}

/**
 * Texture layers for an attribute → pattern table (QGIS RasterFill categories): at most
 * one for ground-sized textures and one for screen-sized ones, so a blended table costs
 * one or two offscreen composites (`fill-layer-blend`) instead of one per value.
 *
 * Ground-sized textures keep their QGIS width at every zoom and follow the feature's
 * `direction` where QGIS rotates them (`fill-pattern-reference-zoom` /
 * `fill-pattern-rotate`, local MapLibre patch — docs/maplibre-patches.md).
 */
export function surfacePatternLayers(
  groups: readonly SurfacePattern[],
  options: { property?: string; blend?: 'normal' | 'multiply' } = {},
): SurfacePatternLayer[] {
  const { property = 'surface', blend = 'multiply' } = options
  const value: ExpressionSpecification = ['get', property]
  const build = (subset: readonly SurfacePattern[], ground: boolean): SurfacePatternLayer => {
    const pattern: unknown[] = ['match', value]
    const opacity: unknown[] = ['match', value]
    const rotate: unknown[] = ['match', value]
    for (const group of subset) {
      pattern.push([...group.surfaces], group.pattern)
      opacity.push([...group.surfaces], group.opacity)
      if (group.rotate != null) {
        rotate.push([...group.surfaces], ['+', ['coalesce', ['get', 'direction'], 0], group.rotate])
      }
    }
    // Fallbacks are unreachable behind the filter but required by `match`.
    pattern.push(subset[0]!.pattern)
    opacity.push(0)
    rotate.push(0)
    return {
      role: ground ? 'pattern' : 'pattern-px',
      filter: ['in', value, ['literal', subset.flatMap((g) => [...g.surfaces])]] as FilterSpecification,
      paint: {
        'fill-pattern': pattern as ExpressionSpecification,
        'fill-opacity': opacity as ExpressionSpecification,
        ...(ground ? { 'fill-pattern-reference-zoom': TEXTURE_REF_ZOOM } : {}),
        ...(ground && rotate.length > 3
          ? { 'fill-pattern-rotate': rotate as ExpressionSpecification }
          : {}),
        ...(blend === 'normal' ? {} : { 'fill-layer-blend': blend }),
      },
    }
  }
  const groundSized = groups.filter((g) => !g.pixelSized)
  const pixelSized = groups.filter((g) => g.pixelSized)
  return [
    ...(groundSized.length ? [build(groundSized, true)] : []),
    ...(pixelSized.length ? [build(pixelSized, false)] : []),
  ]
}
