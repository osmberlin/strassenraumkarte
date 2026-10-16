/**
 * Closed set of QGIS marker images (`style/symbols/**`) packed by `scripts/build-sprite.ts`
 * into the lossless `symbols` sprite sheet (ids `symbols:<path>`), plus the helpers shared
 * with the runtime resolver (`src/lib/missing-style-images.ts`, open-ended
 * `symbols/traffic_signs/<class>/<symbol>` ids — note the slash instead of the colon).
 *
 * Sizing contract — every icon, packed or resolved at runtime, is `ICON_WIDTH_PX` wide in
 * logical (CSS) pixels at `icon-size: 1`; the height follows the source aspect ratio.
 * QGIS marker `size` is the marker *width*, so `icon-size = widthMetres * px/m / ICON_WIDTH_PX`
 * (`iconSizeFromMetres`) gives the QGIS ground size.
 *
 * Resolution is independent of that box: MapLibre samples icons bilinearly without mipmaps,
 * so an icon stored much larger than it is drawn turns into speckle (a 64 px sign drawn
 * 11 px wide loses its outline). Each icon is therefore rasterized at the pixel width it
 * has on the ground at `ICON_REF_ZOOM` (`iconRasterWidthPx`) and the difference to
 * `ICON_WIDTH_PX` goes into the image `pixelRatio`.
 */
import type { ExpressionSpecification } from '@maplibre/maplibre-gl-style-spec'

import { metresToPixels, metresToPixelsAtZoom } from './metres'

/** Logical width (CSS px at icon-size 1) of every `symbols/*` icon. */
export const ICON_WIDTH_PX = 64

/**
 * Zoom at which packed icons are pixel-exact on a 1× screen (the @2× sheet is exact at z20,
 * the camera maximum). One zoom either side stays within 2× bilinear scaling.
 */
export const ICON_REF_ZOOM = 19

/** Raster width (px, 1× sheet) for an icon drawn `groundM` metres wide. */
export function iconRasterWidthPx(groundM: number): number {
  return Math.max(8, Math.round(metresToPixelsAtZoom(groundM, ICON_REF_ZOOM)))
}

/** Marker width assumed for runtime-resolved road-marking signs (data: "width" = 2 m). */
export const RUNTIME_SIGN_GROUND_M = 2

/** icon-size so an icon covers `widthMetres` of ground (QGIS `size * @mercator_scale`). */
export function iconSizeFromMetres(
  widthMetres: number | ExpressionSpecification,
): ExpressionSpecification {
  return metresToPixels(['/', widthMetres, ICON_WIDTH_PX] as ExpressionSpecification)
}

/**
 * QGIS SimpleMarker shapes (`style/symbols/shapes/*.svg`, ids `symbols:shapes/<name>`) are
 * drawn in the marker's own coordinates: centre at 0,0 and the QGIS `size` spanning 2 units.
 * The file box is `SHAPE_BOX` times that, so outlines and off-centre shapes
 * (`filled_arrowhead`, `half_square`) fit and the icon anchor stays the QGIS marker centre.
 */
export const SHAPE_BOX = 1.5

/** `icon-size` for a `symbols:shapes/*` icon from the QGIS marker `size` in metres. */
export function shapeIconSizeFromMetres(
  sizeMetres: number | ExpressionSpecification,
): ExpressionSpecification {
  return iconSizeFromMetres(
    typeof sizeMetres === 'number'
      ? sizeMetres * SHAPE_BOX
      : (['*', sizeMetres, SHAPE_BOX] as ExpressionSpecification),
  )
}

/**
 * `icon-offset` component for a `symbols:shapes/*` icon: a QGIS offset given as a fraction of
 * the marker `size`. `icon-offset` scales with `icon-size` and turns with `icon-rotate`, like
 * a QGIS marker offset turns with the marker angle.
 */
export function shapeOffset(fractionOfSize: number): number {
  return (fractionOfSize * ICON_WIDTH_PX) / SHAPE_BOX
}

/**
 * Layout of a QGIS MarkerLine (`placement: interval`, `rotate: 1`): one icon every
 * `intervalMetres` along the line, x axis of the icon along the line, icon "up" to its left.
 *
 * `symbol-spacing` is in px and must stay ≥ 1 — raise the layer `minzoom` for short intervals.
 * The tiny `text-size` is deliberate although there is no text: MapLibre widens the spacing
 * to at least 4/3 of the "label length", which for an icon is its unscaled sprite width
 * (64 px) × `text-size` / 24 (`getAnchors` in symbol layout). With the default text size no
 * interval below ~57 px survives. MapLibre has no `offset_along_line`: the first icon sits at
 * the start of the line (of each tile's piece of it).
 */
export function markerLineLayout(intervalMetres: number): {
  'symbol-placement': 'line'
  'symbol-spacing': ExpressionSpecification
  'text-size': number
  'icon-rotation-alignment': 'map'
  'icon-pitch-alignment': 'map'
  'icon-allow-overlap': true
  'icon-ignore-placement': true
  'icon-padding': number
} {
  return {
    'symbol-placement': 'line',
    'symbol-spacing': metresToPixels(intervalMetres),
    'text-size': 0.01,
    'icon-rotation-alignment': 'map',
    'icon-pitch-alignment': 'map',
    'icon-allow-overlap': true,
    'icon-ignore-placement': true,
    'icon-padding': 0,
  }
}

/** Values QGIS substitutes for `param(...)` placeholders in SvgMarker files. */
export type SvgParams = {
  fill?: string
  outline?: string
  /** SVG user units (QGIS: stroke px × viewBox width / marker px). */
  outlineWidth?: number
  fillOpacity?: number
  outlineOpacity?: number
}

const PARAM_RE = /param\((fill|fill-opacity|outline|outline-opacity|outline-width)\)([^"';]*)/g

/**
 * Replace QGIS `param(fill) #d0d0d0`-style attribute values with real paint.
 * Browsers and librsvg treat the raw value as invalid (→ black fill). Explicit `params`
 * win, then the default written after the placeholder, then QGIS' own defaults.
 */
export function substituteSvgParams(svg: string, params: SvgParams = {}): string {
  return svg.replace(PARAM_RE, (_all, name: string, rest: string) => {
    const fallback = rest.trim()
    switch (name) {
      case 'fill':
        return params.fill ?? (fallback || '#000000')
      case 'outline':
        return params.outline ?? (fallback || 'none')
      case 'outline-width':
        return String(params.outlineWidth ?? (fallback || 0))
      case 'fill-opacity':
        return String(params.fillOpacity ?? (fallback || 1))
      default:
        return String(params.outlineOpacity ?? (fallback || 1))
    }
  })
}

export type PackedIcon = {
  /** Image id used in `icon-image` (`symbols:<name>`). */
  id: string
  /** Path below `style/symbols/` (SVG or PNG). */
  file: string
  /** QGIS SvgMarker colours for `param(...)` placeholders (ignored by files without them). */
  params?: SvgParams
  /** Largest QGIS marker width in metres — sets the raster resolution only. */
  groundM: number
  /**
   * Resampling kernel for the sprite raster (sharp). Mitchell is softer than the default
   * lanczos3 and closer to how QGIS downsamples the large crown PNGs.
   */
  resample?: 'lanczos3' | 'mitchell'
  /**
   * QGIS dropShadow baked under the image: black, offset `offsetM` at 45° (SE), Gaussian
   * `sigmaFrac` of the marker width, knocked out under the symbol. The sprite grows by
   * `SHADOW_MARGIN` on each side; the marker itself stays ICON_WIDTH_PX logical px wide.
   */
  shadow?: {
    /** Gaussian sigma as a fraction of the marker width. */
    sigmaFrac: number
    /** Shadow alpha (QGIS effect opacity). */
    opacity: number
    /** QGIS offset_distance in map units (metres). */
    offsetM: number
    /** QGIS offset_angle: 0 = north, clockwise (default 135 = lower right). */
    angleDeg?: number
  }
}

/**
 * Margin added around a shadowed icon, as a fraction of its raster width: must cover
 * 3 sigma of the blur plus the offset.
 */
export const SHADOW_MARGIN = 0.5

/** Style `sprite` id of the marker sheet; MapLibre exposes its images as `symbols:<name>`. */
export const SYMBOL_SPRITE_ID = 'symbols'

const P = `${SYMBOL_SPRITE_ID}:`

/** `[file, QGIS width in metres]` → icon with the id derived from the path. */
function plain(entries: [file: string, groundM: number][]): PackedIcon[] {
  return entries.map(([file, groundM]) => ({
    id: P + file.replace(/\.(svg|png)$/i, ''),
    file,
    groundM,
  }))
}

/**
 * `colour` values written by `data/processing/sql/params/params.sql` (default / temporary);
 * QGIS feeds the CSS name straight into the SVG fill.
 */
export const MARKING_ICON_COLOURS = { white: '#ffffff', yellow: '#ffff00' } as const

export const ROAD_MARKING_ARROWS = [
  'left',
  'left;right',
  'left;through',
  'merge_to_left',
  'merge_to_right',
  'right',
  'slight_left',
  'slight_right',
  'through',
  'through;right',
] as const

/** road_marking_node rule "symbol": `"symbol" IN ('bicycle', 'footway', 'wheelchair')`. */
export const ROAD_MARKING_SYMBOLS = ['bicycle', 'footway', 'wheelchair'] as const

/**
 * road_marking_node arrows/symbols: QGIS fill = `"colour"` (static fallback white), outline
 * width 0. White keeps the plain id; other colours get a `-<colour>` suffix
 * (`markingIconSuffix`).
 */
function markingIcons(dir: string, names: readonly string[], groundM: number): PackedIcon[] {
  return Object.entries(MARKING_ICON_COLOURS).flatMap(([colour, fill]) =>
    names.map((name) => ({
      id: `${P}traffic_signs/${dir}/${name}${colour === 'white' ? '' : `-${colour}`}`,
      file: `traffic_signs/${dir}/${name}.svg`,
      params: { fill, outline: 'none', outlineWidth: 0 },
      groundM,
    })),
  )
}

/** Sprite id suffix for a road-marking icon from the feature `colour`. */
export function markingIconSuffix(): ExpressionSpecification {
  return ['match', ['get', 'colour'], 'yellow', '-yellow', ''] as ExpressionSpecification
}

/**
 * One `shapes/<shape>.svg` in the colours of a QGIS SimpleMarker. `sizeM` is the largest QGIS
 * `size`; `outlineWidthM` the QGIS outline width at that size (drawn centred on the edge).
 */
function shapeIcon(
  name: string,
  shape: string,
  sizeM: number,
  fill: string,
  outline?: { color: string; widthM: number },
): PackedIcon {
  return {
    id: `${P}shapes/${name}`,
    file: `shapes/${shape}.svg`,
    params: {
      fill,
      outline: outline?.color ?? 'none',
      // SVG user units: the marker size spans 200.
      outlineWidth: outline ? (outline.widthM / sizeM) * 200 : 0,
    },
    groundM: sizeM * SHAPE_BOX,
  }
}

/** Sprite ids of the packed SimpleMarker shapes. */
export const SHAPE_ICON = {
  /** landscape_way MarkerLine ticks, landscape_node peak. */
  landscapeTriangle: `${P}shapes/equilateral_triangle-landscape`,
  /** road_marking_way sharks teeth; `markingIconSuffix()` selects the colour. */
  sharksTooth: `${P}shapes/triangle-marking`,
  /** feature_node (foreground) guard_stone. */
  guardStone: `${P}shapes/filled_arrowhead-guard_stone`,
  /** barrier_way bollard rows. */
  bollard: `${P}shapes/circle-bollard`,
  /** separation bollard / flex_post rows (outlined). */
  separationBollard: `${P}shapes/circle-separation_bollard`,
  separationFlexPost: `${P}shapes/circle-separation_flex_post`,
  /** separation vertical_panel. */
  verticalPanel: `${P}shapes/half_square-vertical_panel`,
  /** highway_oneway arrowhead (QGIS `arrowhead`, size by highway class via icon-size). */
  oneway: `${P}shapes/arrowhead-oneway`,
} as const

/**
 * Sprite ids of the feature_node SimpleMarkers that QGIS draws as boxes or an X rather than
 * circles. `icon-size` for them is `sizeM * SHAPE_BOX` (see `shapeIconSizeFromMetres`).
 */
export const FEATURE_SHAPE_ICON = {
  clock: `${P}shapes/square-clock`,
  parkingTickets: `${P}shapes/square-parking_tickets`,
  chargingStation: `${P}shapes/square-charging_station`,
  streetCabinet: `${P}shapes/half_square-street_cabinet`,
  gritBin: `${P}shapes/half_square-grit_bin`,
  streetLamp: `${P}shapes/street_lamp`,
} as const

/**
 * QGIS tree crown RasterMarker variants (`symbols/trees/<kind><nn>.png`): broadleaved01–19,
 * needleleaved01–06, shrub01–06. QGIS picks one per feature with rand(…, "tid"); the style
 * picks one from `crown_seed` (osm_id hash) instead, so every variant is packed.
 */
export const CROWN_VARIANT_COUNT = {
  broadleaved: 19,
  needleleaved: 6,
  shrub: 6,
} as const

export type CrownKind = keyof typeof CROWN_VARIANT_COUNT

/** Sprite id prefix of a crown kind (`symbols:trees/<kind>` + two-digit variant). */
export function crownIconPrefix(kind: CrownKind): string {
  return `${P}trees/${kind}`
}

/**
 * QGIS `tree crown` dropShadow (see PACKED_ICONS). QGIS blurs over 3 map units; a wide blur
 * (sigma 0.15 of the crown) measured worse against QGIS tiles than a tight one (0.05).
 */
const TREE_SHADOW = { sigmaFrac: 0.05, opacity: 0.4, offsetM: 0.4, angleDeg: 135 } as const

/**
 * QGIS `street parking` cars (`symbols/cars/<type>.svg`). The SvgMarker fill is the feature
 * `colour`, which is data (13 values today). MapLibre cannot tint a multi-colour SVG, so each
 * type is baked once per colour in `CAR_COLOURS` (unknown colours → grey default).
 */
export const CAR_TYPES = [
  'motor_vehicle01',
  'motor_vehicle02',
  'hgv',
  'taxi',
  'emergency',
  'bus',
] as const

/** QGIS SvgMarker default fill (`param(fill) #808080`). */
export const CAR_DEFAULT_COLOUR = '#808080'

/** Distinct `street_parking_point.colour` values (lowercase hex), most frequent first. */
export const CAR_COLOURS = [
  '#949494',
  '#d4d4d3',
  '#60605f',
  '#b4b4b4',
  '#66798d',
  '#af6a6d',
  '#6f8a75',
  '#9a8e7e',
  '#beac6f',
  '#947c94',
  '#c88f66',
  '#ccc6ad',
  '#77a3c6',
] as const

/** QGIS SvgMarker width of a car (`size` 2.4 m); height follows the SVG (250×440). */
export const CAR_GROUND_M = 2.4

/**
 * QGIS `street parking (> z17)`: dropShadow (black α 0.5, blur 0.8 map units, offset 0.5
 * map units at 40°). The blur reads much tighter than a Gaussian of 0.8 m against the QGIS
 * tiles, so σ = 0.05 m and α 0.2 are used (fitted by eye, like the crowns).
 * The `<= z17` layers have no shadow, so they get the plain variant.
 */
const CAR_SHADOW = { sigmaFrac: 0.05 / CAR_GROUND_M, opacity: 0.2, offsetM: 0.5, angleDeg: 40 } as const

function carColourKey(hex: string): string {
  return hex.replace('#', '').toLowerCase()
}

/** Sprite id of a car variant (`symbols:cars/<type>-<rrggbb>[-shadow]`). */
export function carIconName(type: string, hex: string, shadowed: boolean): string {
  return `cars/${type}-${carColourKey(hex)}${shadowed ? '-shadow' : ''}`
}

/**
 * Packed car variants: every type × every `CAR_COLOURS` entry (+ default), plain and with the
 * baked shadow. The 1× raster is ~26 px wide, so the whole set stays small.
 */
function carIcons(): PackedIcon[] {
  const colours = [CAR_DEFAULT_COLOUR, ...CAR_COLOURS]
  return CAR_TYPES.flatMap((type) =>
    colours.flatMap((hex) =>
      [false, true].map((shadowed) => ({
        id: `${P}${carIconName(type, hex, shadowed)}`,
        file: `cars/${type}.svg`,
        params: { fill: hex },
        groundM: CAR_GROUND_M,
        ...(shadowed ? { shadow: CAR_SHADOW } : {}),
      })),
    ),
  )
}

/**
 * `icon-image` expression for a `street_parking_point` feature: the type and a colour match
 * (unknown colour → default grey) select the baked variant.
 */
export function carIconExpression(shadowed: boolean): ExpressionSpecification {
  const colourKey: unknown[] = ['match', ['downcase', ['to-string', ['coalesce', ['get', 'colour'], '']]]]
  for (const hex of CAR_COLOURS) colourKey.push(hex, carColourKey(hex))
  colourKey.push(carColourKey(CAR_DEFAULT_COLOUR))
  const suffix = shadowed ? '-shadow' : ''
  return [
    'concat',
    `${SYMBOL_SPRITE_ID}:cars/`,
    ['coalesce', ['get', 'type'], CAR_TYPES[0]],
    '-',
    colourKey as ExpressionSpecification,
    suffix,
  ] as ExpressionSpecification
}

/**
 * `icon-image` expression for a tree crown: the kind (crown, needleleaved or shrub) and a
 * two-digit variant from `crown_seed` (`ABS(osm_id) % 1000`), so a tree keeps its crown.
 */
export function crownIconExpression(
  kind: CrownKind,
  seed: ExpressionSpecification = ['coalesce', ['get', 'crown_seed'], 0] as ExpressionSpecification,
): ExpressionSpecification {
  const index = ['+', ['%', seed, CROWN_VARIANT_COUNT[kind]], 1] as ExpressionSpecification
  return [
    'concat',
    crownIconPrefix(kind),
    ['case', ['<', index, 10], '0', ''],
    ['to-string', index],
  ] as ExpressionSpecification
}

function crownIcons(): PackedIcon[] {
  return (Object.keys(CROWN_VARIANT_COUNT) as CrownKind[]).flatMap((kind) =>
    Array.from({ length: CROWN_VARIANT_COUNT[kind] }, (_, i) => {
      const nn = String(i + 1).padStart(2, '0')
      return {
        id: `${crownIconPrefix(kind)}${nn}`,
        file: `trees/${kind}${nn}.png`,
        groundM: 10,
        resample: 'mitchell' as const,
        shadow: TREE_SHADOW,
      }
    }),
  )
}

/**
 * Everything the style references with a fixed id. Colours are the SvgMarker
 * `color` / `outline_color` / `outline_width` options from `style/strassenraumkarte.qgz`.
 */
export const PACKED_ICONS: PackedIcon[] = [
  ...plain([
    ['amenity/bench.svg', 1.7],
    ['amenity/bench_backrest_no.svg', 1.7],
    ['amenity/bicycle.svg', 1.8],
    ['amenity/bicycle_rental.svg', 1.8],
    ['amenity/cargo_bike.svg', 2.2],
    ['amenity/small_electric_vehicle.svg', 1.8],
    ['amenity/mobility_hub.svg', 2.2],
    ['amenity/mobility_hub_Jelbi.svg', 2.2],
    ['amenity/post_box_green.svg', 1.2],
    ['amenity/post_box_yellow.svg', 1.2],
    ['amenity/telephone.svg', 1.2],
    ['amenity/waste_basket.svg', 0.8],
    ['amenity/loading_ramp.png', 2.5],
    ['leisure/picnic_table.svg', 1.75],
    ['leisure/table_tennis.svg', 1.7],
    ['leisure/table_tennis_net_no.svg', 1.7],
    ['leisure/table_tennis_net_yes.svg', 1.7],
    ['man_made/manhole.svg', 0.75],
    ['tourism/artwork.svg', 1.6],
    ['tourism/guidepost.svg', 1.8],
    ['tourism/information.svg', 1.2],
    ['tourism/viewpoint.svg', 3],
    ['tourism/viewpoint_all_directions.svg', 5.2],
    ['historic/memorial.svg', 1.2],
    ['public_transport/subway.svg', 2],
    ['public_transport/s-train.svg', 2.2],
    // barrier_node 0.5 / 0.6 m, landscape_node 1 m
    ['rock/rock01.png', 1],
    ['traffic_signs/street_name_sign.svg', 1.4],
    // feature_node traffic_calming (QGIS RasterMarkers, width 3 m)
    ['traffic_calming/bump.png', 3],
    ['traffic_calming/hump.png', 3],
    // feature_node traffic_sign rules (arrows 222*, vertical panels 605*) — fixed ids.
    ['traffic_signs/DE/222.svg', 0.9],
    ['traffic_signs/DE/222-10.svg', 0.9],
    ['traffic_signs/DE/605-10.svg', 0.4],
    ['traffic_signs/DE/605-11.svg', 0.4],
    ['traffic_signs/DE/605-20.svg', 0.4],
    ['traffic_signs/DE/605-21.svg', 0.4],
  ]),
  // feature_node / feature_polygon fountain: color 163,150,217, outline_width 0.
  {
    id: `${P}amenity/fountain`,
    file: 'amenity/fountain.svg',
    params: { fill: '#a396d9', outline: '#232323', outlineWidth: 0 },
    groundM: 3.2,
  },
  // feature_node recycling: color 128,128,128, outline 35,35,35 @ 0.03 m on a 1.4 m marker
  // (viewBox 580 → 0.03 / 1.4 * 580 user units).
  {
    id: `${P}amenity/recycling`,
    file: 'amenity/recycling.svg',
    params: { fill: '#808080', outline: '#232323', outlineWidth: (0.03 / 1.4) * 580 },
    groundM: 1.4,
  },
  // feature_polygon recycling / waste_disposal: color 80,80,80, outline_width 0.
  {
    id: `${P}amenity/recycling_container`,
    file: 'amenity/recycling.svg',
    params: { fill: '#505050', outline: '#232323', outlineWidth: 0 },
    groundM: 2,
  },
  // feature_node (foreground) + feature_polygon toilets: color 80,80,80, outline_width 0.
  {
    id: `${P}amenity/toilets`,
    file: 'amenity/toilets.svg',
    params: { fill: '#505050', outline: '#232323', outlineWidth: 0 },
    groundM: 1.6,
  },
  // Arrows: 5 m long → 1.5 m wide. Symbols: "width" 0.65–0.7 m.
  ...markingIcons('arrows', ROAD_MARKING_ARROWS, 1.5),
  ...markingIcons('symbols', ROAD_MARKING_SYMBOLS, 0.7),
  // SimpleMarker shapes. landscape_way ticks 0.8 / 1.6 m (peak 1.5 m): color 150,82,32.
  shapeIcon('equilateral_triangle-landscape', 'equilateral_triangle', 1.6, '#965220'),
  // road_marking_way sharks_teeth: fill = "colour" (fallback white), size = first dash (0.5 m).
  ...Object.entries(MARKING_ICON_COLOURS).map(([colour, fill]) =>
    shapeIcon(`triangle-marking${colour === 'white' ? '' : `-${colour}`}`, 'triangle', 0.5, fill),
  ),
  // guard_stone: color and outline 128,128,128, outline 0.1 m on a 0.5 m marker.
  shapeIcon('filled_arrowhead-guard_stone', 'filled_arrowhead', 0.5, '#808080', {
    color: '#808080',
    widthM: 0.1,
  }),
  // barrier_way bollard: circle 0.4 m, color 80,80,80, no outline.
  shapeIcon('circle-bollard', 'circle', 0.4, '#505050'),
  // separation bollard 0.35 m (80,80,80) / flex_post 0.3 m (160,160,160): outline
  // 237,237,237 @ 0.1 m.
  shapeIcon('circle-separation_bollard', 'circle', 0.35, '#505050', {
    color: '#ededed',
    widthM: 0.1,
  }),
  shapeIcon('circle-separation_flex_post', 'circle', 0.3, '#a0a0a0', {
    color: '#ededed',
    widthM: 0.1,
  }),
  // separation vertical_panel: color 80,80,80, outline 237,237,237 @ 0.1 m on a 0.35 m marker.
  shapeIcon('half_square-vertical_panel', 'half_square', 0.35, '#505050', {
    color: '#ededed',
    widthM: 0.1,
  }),
  // feature_node boxes (QGIS square / half_square markers, not circles).
  shapeIcon('square-clock', 'square', 0.6, '#63d9c6', { color: '#232323', widthM: 0.06 }),
  shapeIcon('square-parking_tickets', 'square', 0.5, '#63d9c6', { color: '#808080', widthM: 0.04 }),
  shapeIcon('square-charging_station', 'square', 0.5, '#74b0d9', { color: '#505050', widthM: 0.05 }),
  shapeIcon('half_square-street_cabinet', 'half_square', 0.8, '#63d9c6', {
    color: '#808080',
    widthM: 0.05,
  }),
  shapeIcon('half_square-grit_bin', 'half_square', 1, '#e9a95f', { color: '#8b8579', widthM: 0.2 }),
  // Plain street lamp: grey disc with a grey X (cross2 is an outline-only marker).
  shapeIcon('street_lamp', 'street_lamp', 0.67, '#dadada', { color: '#808080', widthM: 0.11 }),
  // highway_oneway arrowhead (size = 2.5 m, the largest). The QGIS tiles show faint pale
  // chevrons, not the red fill of the symbol definition, so the fill is a light translucent
  // tint with a thin grey edge.
  shapeIcon('arrowhead-oneway', 'filled_arrowhead', 2.5, 'rgba(255,255,255,0.3)', {
    color: 'rgba(110,110,120,0.5)',
    widthM: 0.2,
  }),
  // Crowns: diameter_crown 1–23 m, mostly 6–12 m. QGIS dropShadow: black α 0.4, blur
  // 3 MapUnits, offset 0.4 MapUnits at 45°. Baked in so each crown shades the crowns drawn
  // before it, and knocked out under its own silhouette (QGIS shows no shadow inside it).
  ...crownIcons(),
  // Street parking cars: plain (z15–17) and shadowed (z17+) per type × colour.
  ...carIcons(),
]
