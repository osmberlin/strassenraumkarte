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
    maxzoom: 18,
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
    maxzoom: 18,
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
    maxzoom: 18,
    paint: 'circle',
    group: 'ground',
  },
  {
    id: 'sandpit',
    table: 'playground_polygon',
    filter: "playground = 'sandpit'",
    columns: ['osm_id', 'playground'],
    minzoom: 15,
    maxzoom: 18,
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
    maxzoom: 18,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'wetland',
    table: 'water_body',
    filter: "\"natural\" = 'wetland'",
    columns: ['osm_id', '"natural"'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'ground',
  },
  {
    id: 'waterway_clipped',
    table: 'waterway_clipped',
    columns: ['osm_id', 'width', 'waterway', 'tunnel', 'covered'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'ground',
  },
  // G3 landscape (above water in QGIS land group)
  {
    id: 'landscape_way',
    table: 'landscape_way',
    // Length drives QGIS width / MarkerLine spacing (threshold 20 m).
    columns: ['osm_id', 'class', 'subclass', 'ST_Length(geom) AS length'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'ground',
  },
  {
    id: 'landscape_node',
    table: 'landscape_node',
    // Materialise rand(0,360) rock/stone rotation (not reproducible in MapLibre).
    columns: [
      'osm_id',
      'class',
      'subclass',
      '((osm_id % 360) + 360) % 360 AS rotation',
    ],
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
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
    maxzoom: 18,
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
    maxzoom: 18,
    paint: 'line',
    group: 'streets',
  },
  {
    id: 'highway_service',
    table: 'highway_service',
    columns: ['class', 'width', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'streets',
  },
  // G3 bridges & railway (×7 OSM layer stack, under highway within each bucket)
  {
    id: 'bridge_shade',
    table: 'bridge_shade',
    columns: ['osm_id', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'streets',
  },
  {
    id: 'bridge',
    table: 'bridge',
    columns: ['osm_id', 'layer', 'man_made', 'name'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'streets',
  },
  {
    id: 'railway_way',
    table: 'railway_way',
    columns: ['osm_id', 'railway', 'gauge', 'usage', 'service', 'tunnel', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'streets',
  },
  {
    id: 'railway_node',
    table: 'railway_node',
    columns: ['osm_id', 'railway', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
    group: 'streets',
  },

  // buildings z15–17
  {
    id: 'building',
    table: 'building',
    columns: ['osm_id', 'height'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'buildings',
  },
  {
    id: 'building_parts_dissolved_height',
    table: 'building_parts_dissolved_height',
    columns: ['height'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'buildings',
  },
  {
    id: 'building_shade',
    table: 'building_shade',
    columns: [],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'buildings',
  },
  {
    id: 'building_lines',
    table: 'building_lines',
    columns: ['class'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'buildings',
  },
  {
    // Point labels only — QGIS `housenumber` layer (addr:housenumber).
    id: 'housenumber',
    table: 'housenumber',
    columns: ['osm_id', '"addr:housenumber"'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
    group: 'labels',
  },

  // detail — markings/playground from archive minzoom (QGIS has no scale gate)
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
    minzoom: 15,
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
    minzoom: 15,
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
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    id: 'separation',
    table: 'separation',
    columns: ['separation', 'layer'],
    minzoom: 15,
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
      // Since main 05991fe QGIS draws angle rand(-20, 20, "osm_id"); tree.rotation is gone.
      '(((osm_id % 41) + 41) % 41 - 20)::int AS rotation',
      'ref',
      // QGIS crown image: needleleaved.png vs broadleaved.png
      'leaf_type',
      // Picks one of the packed crown variants (QGIS rand(…, "tid") is not reproducible).
      '(ABS(osm_id) % 1000)::int AS crown_seed',
    ],
    // QGIS `tree crown (<= z17)` / `(> z17)` have no minimum scale: crowns and trunks at every zoom.
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    // QGIS `street parking (<= z17)` / `(> z17)`: SvgMarker car, fill = colour, angle = angle.
    id: 'street_parking_point',
    table: 'street_parking_point',
    columns: ['type', 'colour', 'angle', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    // QGIS `kerb` / `kerb shade` (barrier = kerb, kerb != flush for the shade). Kept apart from
    // barrier_way so the kerbs exist from z15, where QGIS draws the shade (1:8000 and closer).
    id: 'kerb',
    table: 'barrier_way',
    filter: "barrier = 'kerb'",
    columns: ['osm_id', 'kerb', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    // QGIS `highway_oneway`: arrowhead MarkerLine on one-way carriageways (interval 12 m).
    id: 'highway_oneway',
    table: 'highway_oneway',
    columns: ['"oneway:bicycle"', 'dual_carriageway', 'highway', 'type', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'streets',
  },
  {
    // QGIS `tunnel_entrance outline` / `shade`: road tunnel mouths, layer-stacked.
    id: 'tunnel_entrance',
    table: 'tunnel_entrance',
    filter: "type = 'road'",
    columns: ['layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'detail',
  },

  // G6 furniture & barriers — tippecanoe z17–18 (street furniture reads at z17+)
  {
    id: 'feature_node',
    table: 'feature_node',
    columns: [
      'osm_id',
      'class',
      'subclass',
      'access',
      'capacity',
      'diameter',
      'direction',
      'support',
      'layer',
    ],
    minzoom: 17,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    id: 'feature_way',
    table: 'feature_way',
    columns: ['osm_id', 'class', 'subclass', 'layer'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'feature_polygon',
    table: 'feature_polygon',
    columns: [
      'osm_id',
      'class',
      'subclass',
      'capacity',
      'direction',
      'layer',
      'ST_Area(geom) AS area',
    ],
    minzoom: 17,
    maxzoom: 18,
    paint: 'fill',
    group: 'detail',
  },
  {
    id: 'barrier_node',
    table: 'barrier_node',
    columns: [
      'osm_id',
      'barrier',
      'foot',
      'bicycle',
      'motor_vehicle',
      'layer',
    ],
    minzoom: 17,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    id: 'barrier_way',
    table: 'barrier_way',
    // Kerbs have their own source-layer `kerb` (z15+).
    filter: "barrier IS DISTINCT FROM 'kerb'",
    columns: ['osm_id', 'barrier', 'layer'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    id: 'barrier_polygon',
    table: 'barrier_polygon',
    columns: ['osm_id', 'barrier', 'layer'],
    minzoom: 17,
    maxzoom: 18,
    paint: 'fill',
    group: 'detail',
  },
  {
    id: 'playground_node',
    table: 'playground_node',
    columns: ['osm_id', 'playground', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
    group: 'detail',
  },
  {
    id: 'playground_way',
    table: 'playground_way',
    columns: ['osm_id', 'playground', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'detail',
  },
  {
    // Sandpit already exported as `sandpit` in ground (G1).
    id: 'playground_polygon',
    table: 'playground_polygon',
    filter: "playground IS DISTINCT FROM 'sandpit'",
    columns: ['osm_id', 'playground', 'layer'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'detail',
  },

  // labels z15–17
  {
    id: 'label_highway',
    table: 'label_highway',
    columns: ['name', 'class', 'zoom'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'line',
    group: 'labels',
  },
  {
    id: 'label_waterway',
    table: 'label_waterway',
    // `waterway` drives QGIS colour / buffer swap (stream vs river).
    columns: ['name', 'waterway'],
    minzoom: 15,
    maxzoom: 18,
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
    maxzoom: 18,
    paint: 'fill',
    group: 'labels',
  },
  {
    id: 'place_node',
    table: 'place_node',
    filter: "name IS NOT NULL AND name <> ''",
    columns: ['osm_id', 'place', 'name'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'circle',
    group: 'labels',
  },
  {
    id: 'place_polygon',
    table: 'place_polygon',
    filter: "name IS NOT NULL AND name <> ''",
    columns: ['osm_id', 'place', 'name', 'ST_Area(geom) AS area'],
    minzoom: 15,
    maxzoom: 18,
    paint: 'fill',
    group: 'labels',
  },
]

export const SOURCE_ID = 'strassenraumkarte'

/**
 * Tippecanoe archive high zoom. Every layer’s `maxzoom` must equal this, otherwise
 * MapLibre requests z18 tiles (source.maxzoom) that only contain the high-zoom
 * groups (e.g. detail) and streets/buildings/ground disappear.
 */
export const ARCHIVE_MAXZOOM = 18

/** Lowest tippecanoe minzoom across layers — also the PMTiles archive minZoom. */
export const SOURCE_MINZOOM = Math.min(...LAYERS.map((l) => l.minzoom))

/**
 * Highest tippecanoe maxzoom across layers — also the PMTiles archive maxZoom.
 * Keep the MapLibre vector `source.maxzoom` at this value so z19–20 overscale
 * parent tiles instead of requesting missing archive levels.
 */
export const SOURCE_MAXZOOM = Math.max(ARCHIVE_MAXZOOM, ...LAYERS.map((l) => l.maxzoom))

/** Map camera: no tiles below archive min; overzoom above archive max to z20. */
export const MAP_MIN_ZOOM = SOURCE_MINZOOM
export const MAP_MAX_ZOOM = 20

export const TILE_GROUPS = ['ground', 'streets', 'buildings', 'detail', 'labels'] as const

export type TileGroup = (typeof TILE_GROUPS)[number]
