/**
 * Single source of truth for vector export / tippecanoe layer groups.
 *
 * Prep pass: export osm_id (when present) + geom only; style is geometry-type based.
 * `highway path` from the plan is covered by `highway_area` (footway/path/cycleway areas).
 */

export type GeomKind = 'fill' | 'line' | 'circle'

export type LayerDef = {
  /** Tippecanoe / MapLibre source-layer id */
  id: string
  /** PostGIS table in public schema */
  table: string
  /** Optional SQL WHERE (no leading WHERE) */
  filter?: string
  /** Extra SELECT columns besides geom (quoted identifiers as needed) */
  columns: string[]
  /** Tippecanoe minzoom (-Z) */
  minzoom: number
  /** Tippecanoe maxzoom (-z); MapLibre overzooms above this */
  maxzoom: number
  /** How the basic preview paints this layer */
  paint: GeomKind
  /** Tippecanoe build group (one tippecanoe run per group, then tile-join) */
  group: 'ground' | 'streets' | 'buildings' | 'detail' | 'labels'
}

export const LAYERS: LayerDef[] = [
  // ground z15–16
  {
    id: 'landuse',
    table: 'landuse',
    columns: ['osm_id'],
    minzoom: 15,
    maxzoom: 16,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'water_body_dissolved',
    table: 'water_body_dissolved',
    columns: [],
    minzoom: 15,
    maxzoom: 16,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'waterway_clipped',
    table: 'waterway_clipped',
    columns: [],
    minzoom: 15,
    maxzoom: 16,
    paint: 'line',
    group: 'ground',
  },

  // streets z15–17
  {
    id: 'highway_area',
    table: 'highway_area',
    columns: ['osm_id', 'layer'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
    group: 'streets',
  },
  {
    id: 'highway_service',
    table: 'highway_service',
    columns: ['layer'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'streets',
  },

  // buildings z15–17
  {
    id: 'building',
    table: 'building',
    columns: ['osm_id'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
    group: 'buildings',
  },
  {
    id: 'building_parts_dissolved_height',
    table: 'building_parts_dissolved_height',
    columns: [],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
    group: 'buildings',
  },
  {
    id: 'building_shade',
    table: 'building_shade',
    columns: [],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
    group: 'buildings',
  },
  {
    id: 'building_lines',
    table: 'building_lines',
    columns: [],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'buildings',
  },

  // detail z17–18
  {
    id: 'road_marking_polygon',
    table: 'road_marking_polygon',
    columns: [],
    minzoom: 17,
    maxzoom: 18,
    paint: 'fill',
    group: 'detail',
  },
  {
    id: 'road_marking_way',
    table: 'road_marking_way',
    columns: ['osm_id'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'road_marking_node',
    table: 'road_marking_node',
    columns: ['osm_id'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    id: 'separation',
    table: 'separation',
    columns: [],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'tactile_paving',
    table: 'tactile_paving',
    columns: [],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'tree',
    table: 'tree',
    columns: ['osm_id'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },

  // labels z15–17 (line geometries used for placement later)
  {
    id: 'label_highway',
    table: 'label_highway',
    columns: [],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'labels',
  },
  {
    id: 'label_waterway',
    table: 'label_waterway',
    columns: ['name'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'labels',
  },
]

export const SOURCE_ID = 'strassenraumkarte'

/** Lowest tippecanoe minzoom across layers — also the PMTiles archive minZoom. */
export const SOURCE_MINZOOM = Math.min(...LAYERS.map((l) => l.minzoom))

/**
 * Highest tippecanoe maxzoom across layers — also the PMTiles archive maxZoom.
 * Keep the MapLibre vector `source.maxzoom` at this value so z19–20 overscale
 * parent tiles instead of requesting missing archive levels.
 */
export const SOURCE_MAXZOOM = Math.max(...LAYERS.map((l) => l.maxzoom))

/** Map camera: no tiles below archive min; overzoom above archive max to z20. */
export const MAP_MIN_ZOOM = SOURCE_MINZOOM
export const MAP_MAX_ZOOM = 20

export const TILE_GROUPS = ['ground', 'streets', 'buildings', 'detail', 'labels'] as const

export type TileGroup = (typeof TILE_GROUPS)[number]
