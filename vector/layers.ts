/**
 * Single source of truth for vector export / tippecanoe layer groups.
 *
 * Columns are the styled attributes needed for the QGIS-faithful MapLibre port (w4c).
 * Identifiers with colons/keywords are double-quoted for PostgreSQL.
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
  /** Fallback geometry family for legend / prep */
  paint: GeomKind
  /** Tippecanoe build group (one tippecanoe run per group, then tile-join) */
  group: 'ground' | 'streets' | 'buildings' | 'detail' | 'labels'
}

export const LAYERS: LayerDef[] = [
  // ground z15–16
  {
    id: 'landuse',
    table: 'landuse',
    // `name` + area for G12 landuse labels (size hide when area/scale is small).
    columns: ['osm_id', 'class', 'surface', 'direction', 'name', 'ST_Area(geom) AS area'],
    minzoom: 15,
    maxzoom: 16,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'pitch',
    table: 'pitch',
    columns: [
      'osm_id',
      'sport',
      'surface',
      '"surface:colour"',
      'direction',
      'hoops',
    ],
    minzoom: 15,
    maxzoom: 16,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'pitch_markings',
    table: 'pitch_markings',
    columns: [
      'osm_id',
      'sport',
      'surface',
      '"surface:colour"',
      'hoops',
      'dist_long',
      'dist_short',
      'direction',
    ],
    minzoom: 15,
    maxzoom: 16,
    paint: 'circle',
    group: 'ground',
  },
  {
    id: 'sandpit',
    table: 'playground_polygon',
    filter: "playground = 'sandpit'",
    columns: ['osm_id', 'playground'],
    minzoom: 15,
    maxzoom: 16,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'water_body_dissolved',
    table: 'water_body_dissolved',
    // Area (m², EPSG:3857) + QGIS shoreline max distance:
    // clamp(10 * log10($area) - 25, 1.5, 20) — drives Shapeburst band widths.
    columns: [
      'ST_Area(geom) AS area',
      'GREATEST(1.5, LEAST(20.0, 10.0 * LOG(ST_Area(geom)) / LOG(10.0) - 25.0)) AS shore_m',
    ],
    minzoom: 15,
    maxzoom: 16,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'wetland',
    table: 'water_body',
    filter: "\"natural\" = 'wetland'",
    columns: ['osm_id', '"natural"'],
    minzoom: 15,
    maxzoom: 16,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'waterway_clipped',
    table: 'waterway_clipped',
    columns: ['osm_id', 'width', 'waterway', 'tunnel', 'covered'],
    minzoom: 15,
    maxzoom: 16,
    paint: 'line',
    group: 'ground',
  },

  // streets z15–17
  {
    id: 'highway_area',
    table: 'highway_area',
    columns: [
      'osm_id',
      'layer',
      '"area:highway"',
      'surface',
      '"sett:length"',
      'type',
      'class',
      'direction',
    ],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
    group: 'streets',
  },
  {
    // QGIS `path (way, *)` — table highway filtered to type=path (footway/path/cycleway/steps/…).
    id: 'highway_path',
    table: 'highway',
    filter: "type = 'path'",
    columns: [
      'highway',
      'class',
      'width',
      'layer',
      'informal',
      'is_sidepath',
      'crossing',
      'tunnel',
      'name',
    ],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'streets',
  },
  {
    id: 'highway_service',
    table: 'highway_service',
    columns: ['class', 'width', 'layer'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'streets',
  },

  // buildings z15–17
  {
    id: 'building',
    table: 'building',
    columns: ['osm_id', 'height'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
    group: 'buildings',
  },
  {
    id: 'building_parts_dissolved_height',
    table: 'building_parts_dissolved_height',
    columns: ['height'],
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
    columns: ['class'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'buildings',
  },
  {
    // Point labels only — QGIS `housenumber` layer (addr:housenumber).
    id: 'housenumber',
    table: 'housenumber',
    columns: ['osm_id', '"addr:housenumber"'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'circle',
    group: 'labels',
  },

  // detail z17–18
  {
    id: 'road_marking_polygon',
    table: 'road_marking_polygon',
    columns: [
      'road_marking',
      'pattern',
      'colour',
      'direction',
      'class',
      'type',
      'layer',
    ],
    minzoom: 17,
    maxzoom: 18,
    paint: 'fill',
    group: 'detail',
  },
  {
    id: 'road_marking_way',
    table: 'road_marking_way',
    columns: [
      'osm_id',
      'road_marking',
      'stroke',
      'width',
      'colour',
      'dasharray',
      'pattern',
      'layer',
    ],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'road_marking_node',
    table: 'road_marking_node',
    columns: [
      'osm_id',
      'road_marking',
      'class',
      'arrow',
      'symbol',
      'direction',
      'length',
      'width',
      'colour',
      'layer',
    ],
    minzoom: 17,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    id: 'separation',
    table: 'separation',
    columns: ['separation', 'layer'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'tactile_paving',
    table: 'tactile_paving',
    columns: ['class', 'layer'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'tree',
    table: 'tree',
    // Materialise fallback crown diameter (QGIS randf is not reproducible in MapLibre).
    columns: [
      'osm_id',
      '"natural"',
      'COALESCE(diameter_crown, CASE WHEN "natural" = \'shrub\' THEN 4.5 ELSE 7 END) AS diameter_crown',
      'COALESCE(circumference, 1.57) AS circumference',
      'rotation',
      'ref',
    ],
    minzoom: 17,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },

  // labels z15–17
  {
    id: 'label_highway',
    table: 'label_highway',
    columns: ['name', 'class', 'zoom'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'labels',
  },
  {
    id: 'label_waterway',
    table: 'label_waterway',
    // `waterway` drives QGIS colour / buffer swap (stream vs river).
    columns: ['name', 'waterway'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'line',
    group: 'labels',
  },
  {
    // Named water polygons — separate from wetland / dissolved fill layers.
    id: 'label_water_body',
    table: 'water_body',
    filter: "name IS NOT NULL AND name <> ''",
    columns: ['osm_id', 'name', '"natural"', 'water', 'ST_Area(geom) AS area'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
    group: 'labels',
  },
  {
    id: 'place_node',
    table: 'place_node',
    filter: "name IS NOT NULL AND name <> ''",
    columns: ['osm_id', 'place', 'name'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'circle',
    group: 'labels',
  },
  {
    id: 'place_polygon',
    table: 'place_polygon',
    filter: "name IS NOT NULL AND name <> ''",
    columns: ['osm_id', 'place', 'name', 'ST_Area(geom) AS area'],
    minzoom: 15,
    maxzoom: 17,
    paint: 'fill',
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
