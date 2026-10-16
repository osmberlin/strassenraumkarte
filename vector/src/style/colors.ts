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
  // outdoor_seating: no SimpleFill in QGIS — LinePatternFill hatch only (see patterns.ts)
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
 * `landuse surface` and `pitch surface` (identical categories; `pitch surface` does not
 * rotate sett in QGIS — ignored). MapUnit textures are baked to QGIS ground width at
 * TEXTURE_REF_ZOOM in `bun run sprite`.
 */
/**
 * Zoom at which `bun run sprite` bakes ground-metre textures: one logical sprite pixel is
 * one CSS pixel there. `fill-pattern-reference-zoom` (local MapLibre patch) keeps them at
 * that ground size on every other zoom.
 */
export const TEXTURE_REF_ZOOM = 19

export type SurfacePattern = {
  /** Attribute values (`surface`, or `class` for landuse) that share this pattern + opacity. */
  surfaces: readonly string[]
  /** Sprite id (from `bun run sprite`). */
  pattern: string
  opacity: number
  /** QGIS width unit Pixel: the texture is screen-sized, not ground-sized. */
  pixelSized?: true
  /** QGIS angle = "direction" + this (degrees clockwise). Omitted = not rotated. */
  rotate?: number
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
    pixelSized: true,
  },
  {
    surfaces: ['concrete', 'concrete:plates'],
    pattern: 'surface/concrete',
    opacity: 0.15,
  },
  { surfaces: ['grass'], pattern: 'grass', opacity: 0.06, pixelSized: true },
  { surfaces: ['paving_stones'], pattern: 'surface/paving_stones', opacity: 0.07, rotate: 45 },
  { surfaces: ['sett'], pattern: 'surface/sett', opacity: 0.12, rotate: 0 },
  { surfaces: ['woodchips'], pattern: 'woodchips', opacity: 0.1 },
] as const

/**
 * QGIS `landuse` RasterFill per `class` (layer blend Normal). grass / gravel / sand are
 * pixel-sized in QGIS (texture px = screen px); the others have ground-metre widths.
 * `scrub` gets its grass texture from the separate QGIS layer `scrub (width shade)`.
 * `flowerbed` also carries the grass texture in QGIS — only the stronger one is kept;
 * `reef`'s second (wetland) texture is dropped.
 */
export const LANDUSE_CLASS_PATTERNS: readonly SurfacePattern[] = [
  {
    surfaces: [
      'allotments', 'bbq', 'biergarten', 'cemetery', 'dog_park', 'garden', 'grass',
      'greenery', 'park', 'recreation_ground', 'tree_pit', 'village_green',
    ],
    pattern: 'grass',
    opacity: 0.06,
    pixelSized: true,
  },
  {
    surfaces: [
      'forest', 'grassland', 'heath', 'meadow', 'orchard', 'plant_nursery', 'scrub', 'shrub',
      'shrubbery', 'trees', 'tundra', 'vineyard', 'wood',
    ],
    pattern: 'grass',
    opacity: 0.09,
    pixelSized: true,
  },
  {
    surfaces: [
      'bare_rock', 'gravel', 'landfill', 'quarry', 'railway', 'rock', 'scree', 'blockfield',
      'shingle',
    ],
    pattern: 'gravel',
    opacity: 0.08,
    pixelSized: true,
  },
  {
    surfaces: ['basin', 'beach', 'dune', 'salt_pond', 'sand'],
    pattern: 'sand',
    opacity: 0.08,
    pixelSized: true,
  },
  { surfaces: ['flowerbed'], pattern: 'flowerbed', opacity: 0.25 },
  {
    surfaces: ['glacier', 'reef', 'shoal', 'swimming_pool', 'mud'],
    pattern: 'water',
    opacity: 0.2,
  },
  { surfaces: ['woodchips'], pattern: 'woodchips', opacity: 0.1 },
] as const

/**
 * QGIS `highway_area` RasterFill categories (drawSource effect, Multiply).
 * Same textures as above, different alphas.
 */
export const HIGHWAY_SURFACE_PATTERNS: readonly SurfacePattern[] = [
  { surfaces: ['asphalt'], pattern: 'surface/asphalt', opacity: 0.06 },
  {
    surfaces: ['concrete', 'concrete:plates'],
    pattern: 'surface/concrete',
    opacity: 0.35,
    rotate: 0,
  },
  { surfaces: ['paving_stones'], pattern: 'surface/paving_stones', opacity: 0.1, rotate: 45 },
  { surfaces: ['sett'], pattern: 'surface/sett', opacity: 0.12, rotate: 0 },
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
/** Kept for docs/legend parity; building_shade is not painted in MapLibre (no fill blur). */
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
