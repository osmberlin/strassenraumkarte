/** Landuse class → fill from QGIS categorized renderer. */
export const LANDUSE_FILL: Record<string, string> = {
  "allotments": "#dfefce",
  "bare_ground": "#d8dacf",
  "bare_rock": "#cecece",
  "basin": "#e6e6e6",
  "bbq": "#d4e3c4",
  "beach": "#e3e6c0",
  "biergarten": "#d4e3c4",
  "blockfield": "#dbdbdb",
  "brownfield": "#d8dacf",
  "car_rental": "#e8e8e8",
  "cemetery": "#dfefce",
  "college": "#ede6e0",
  "community_centre": "#ede6e0",
  "dog_park": "#d4e3c4",
  "dune": "#e3e6c0",
  "farmland": "#d8dacf",
  "fire_station": "#e8e8e8",
  "fitness_station": "#dce6cb",
  "flowerbed": "#d4e3c4",
  "forest": "#c4d8af",
  "fuel": "#e8e8e8",
  "garden": "#e3d3b2",
  "glacier": "#e5e3ed",
  "grass": "#d4e3c4",
  "grassland": "#cedcbf",
  "gravel": "#dddddd",
  "greenery": "#d4e3c4",
  "greenhouse_horticulture": "#cedcbf",
  "ground": "#d8dacf",
  "heath": "#cedcbf",
  "kindergarten": "#ede6e0",
  "landfill": "#dddddd",
  "meadow": "#cedcbf",
  "miniature_golf": "#dce6cb",
  "orchard": "#cedcbf",
  "outdoor_seating": "#0000ff",
  "park": "#dfefce",
  "parking": "#dbdde1",
  "plant_nursery": "#cedcbf",
  "playground": "#dce6cb",
  "quarry": "#dddddd",
  "railway": "#dddddd",
  "recreation_ground": "#d4e3c4",
  "reef": "#cac7ed",
  "rock": "#cecece",
  "salt_pond": "#e6e6e6",
  "sand": "#e3e6c0",
  "school": "#ede6e0",
  "scree": "#dddddd",
  "scrub": "#c4d8af",
  "shingle": "#dddddd",
  "shoal": "#e3e6c0",
  "shrub": "#c4d8af",
  "shrubbery": "#c4d8af",
  "social_facility": "#ede6e0",
  "swimming_pool": "#cac7ed",
  "traffic_park": "#dce6cb",
  "tree_pit": "#d4e3c4",
  "trees": "#c4d8af",
  "tundra": "#a8c399",
  "village_green": "#d4e3c4",
  "vineyard": "#cedcbf",
  "wood": "#c4d8af",
  "woodchips": "#e0e4d2",
  "mud": "#dfcfbb"
}

export const FOREST_CLASSES = ["forest","scrub","shrub","shrubbery","trees","wood"] as const

/**
 * Shared 19-entry `surface` → sprite `fill-pattern` table for QGIS
 * `landuse surface` and `pitch surface` (identical categories).
 * Ground-metre width / rotation dropped (G0.4 — fixed sprite pixel scale).
 */
export type SurfacePattern = {
  /** OSM `surface` values that share this pattern + opacity. */
  surfaces: readonly string[]
  /** Sprite id (from `bun run sprite`). */
  pattern: string
  opacity: number
}

export const SURFACE_PATTERNS: readonly SurfacePattern[] = [
  {
    surfaces: ['artificial_turf', 'asphalt', 'rubber', 'rubbercrumb', 'tartan'],
    pattern: 'surface/asphalt',
    opacity: 0.06,
  },
  {
    surfaces: [
      'clay',
      'compacted',
      'dirt',
      'earth',
      'fine_gravel',
      'gravel',
      'ground',
      'sand',
    ],
    pattern: 'sand',
    opacity: 0.08,
  },
  {
    surfaces: ['concrete', 'concrete:plates'],
    pattern: 'surface/concrete',
    opacity: 0.15,
  },
  { surfaces: ['grass'], pattern: 'grass', opacity: 0.06 },
  { surfaces: ['paving_stones'], pattern: 'surface/paving_stones', opacity: 0.07 },
  { surfaces: ['sett'], pattern: 'surface/sett', opacity: 0.12 },
  { surfaces: ['woodchips'], pattern: 'woodchips', opacity: 0.1 },
] as const

/** QGIS `pitch` fill CASE fallback. */
export const PITCH_FILL_DEFAULT = '#d1d7c6'
export const SANDPIT_FILL = '#e3e6c0'

export const WATER_FILL = "#cac7ed"
export const WATER_INNER = "#a396d9"
/** Shapeburst shoreline band colour (inward fade approximation). */
export const WATER_SHORE = "#a396d9"
export const WATERWAY_LINE = "#b2abe0"
export const BUILDING_PARTS_FILL = "#ffe9e9"
export const BUILDING_SHADE_FILL = "#232323"
export const BUILDING_LINES = "#808080"
export const TREE_CROWN = "#6b8f4e"
export const TREE_SHADOW = "#232323"
export const TREE_TRUNK = "#8d8a63"
export const MARKING_DEFAULT = "#ffffff"
export const TACTILE = "#d3d3d3"
export const HIGHWAY_BLUR = "#232323"
export const SERVICE_LINE = "#cccccc"

export const HIGHWAY_AREA_DEFAULT = "#a8a8a7"

/** Path (way) fills — QGIS `path (way, fill)`. */
export const PATH_CYCLEWAY = "#d2d1d2"
export const PATH_SIDEWALK = "#ebedd6"
export const PATH_FOOTWAY = "#e1e3bd"
export const PATH_STEPS = "#979c90"
export const PATH_ACCESS_AISLE = "#ffffea"
/** Path casing: sidewalk/sidepath `#d3d3d3`, footway/informal `#979c90`. */
export const PATH_CASING_LIGHT = "#d3d3d3"
export const PATH_CASING_DARK = "#979c90"
