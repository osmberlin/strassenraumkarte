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
   * QGIS dropShadow baked under the image (black, no offset). The sprite grows by
   * the blur margin; the marker itself stays ICON_WIDTH_PX logical px wide.
   */
  shadow?: { /** Blur radius as a fraction of the marker width. */ blurFrac: number; opacity: number }
}

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

/** Sprite ids for the two QGIS tree crown RasterMarkers. */
export const TREE_ICON = {
  broadleaved: `${P}trees/broadleaved`,
  needleleaved: `${P}trees/needleleaved`,
} as const

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
  // Crowns: diameter_crown 1–23 m, mostly 6–12 m. QGIS dropShadow: black α 0.4, blur
  // 3 MapUnits (≈ 0.18 of a 10 m crown = 16.4 MapUnits), offset 0.4 MapUnits (dropped:
  // the icon rotates). Baked in so each crown shades the crowns drawn before it.
  {
    id: TREE_ICON.broadleaved,
    file: 'trees/broadleaved.png',
    groundM: 10,
    shadow: { blurFrac: 0.18, opacity: 0.4 },
  },
  {
    id: TREE_ICON.needleleaved,
    file: 'trees/needleleaved.png',
    groundM: 10,
    shadow: { blurFrac: 0.18, opacity: 0.4 },
  },
]
