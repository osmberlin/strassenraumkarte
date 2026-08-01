/**
 * QGIS paint-effect approximations for MapLibre (no native blur/shadow).
 *
 * Patterns from research/maplibre-special-case-styling (Stamen/Stadia):
 * drive `line-width` and `line-blur` from the *same* interpolate so soft edges
 * scale smoothly; keep glow widths moderate to avoid join artefacts.
 *
 * Zoom expressions must stay top-level (no nesting `['*', metresToPixels(m), k]`).
 * Scale factors are baked into interpolate stops instead.
 */
import type {
  ExpressionSpecification,
  FillLayerSpecification,
  LayerSpecification,
  LineLayerSpecification,
} from '@maplibre/maplibre-gl-style-spec'

import { DEFAULT_LAT, metresToPixelsAtZoom, mmToPixels } from './metres'

export type EffectColor = string | ExpressionSpecification

export type DropShadowOptions = {
  /** Ground-metre blur radius of the soft edge. */
  blurM: number
  /** Ground-metre offset distance. */
  offsetM: number
  /** Direction of the offset in degrees (QGIS: 0 = east, 90 = north). */
  angleDeg: number
  color: EffectColor
  opacity: number | ExpressionSpecification
  lat?: number
}

export type InnerShadowOptions = {
  /** Ground-metre blur (also drives line width when `widthM` omitted). */
  blurM: number
  /** Stroke width in metres; defaults to `blurM`. */
  widthM?: number
  color: EffectColor
  opacity?: number | ExpressionSpecification
  lat?: number
}

export type OuterGlowOptions = {
  blurM: number
  /** Slightly lighter than the fill — caller picks the hex. */
  color: EffectColor
  opacityInner?: number | ExpressionSpecification
  opacityOuter?: number | ExpressionSpecification
  /** Width multiplier for the outer glow (default 2). */
  outerWidthFactor?: number
  lat?: number
}

export type InnerGlowOptions = OuterGlowOptions

export type HighwayInnerBlurOptions = {
  color?: EffectColor
  opacity?: number | ExpressionSpecification
}

type LayerBase = Pick<
  FillLayerSpecification,
  'source' | 'source-layer' | 'minzoom' | 'maxzoom' | 'filter' | 'metadata'
>

/** Exact base-2 metre→px interpolate with an optional linear scale on the stops. */
export function metresInterpolate(
  metres: number,
  scale = 1,
  lat: number = DEFAULT_LAT,
): ExpressionSpecification {
  return [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    15,
    metresToPixelsAtZoom(metres, 15, lat) * scale,
    20,
    metresToPixelsAtZoom(metres, 20, lat) * scale,
  ] as ExpressionSpecification
}

/**
 * Zoom-interpolated [x,y] translate; stop values wrapped in `literal`.
 * QGIS angle: 0 = east, 90 = north; map Y grows south → uy = −sin.
 */
export function metreOffsetTranslate(
  offsetM: number,
  angleDeg: number,
  lat: number = DEFAULT_LAT,
): ExpressionSpecification {
  const rad = (angleDeg * Math.PI) / 180
  const ux = Math.cos(rad)
  const uy = -Math.sin(rad)
  const at = (z: number): ExpressionSpecification => {
    const d = metresToPixelsAtZoom(offsetM, z, lat)
    return ['literal', [d * ux, d * uy]] as ExpressionSpecification
  }
  return [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    15,
    at(15),
    20,
    at(20),
  ] as unknown as ExpressionSpecification
}

/** MM paper-unit ramp (z14–z20) → CSS px; optional linear scale on stops. */
function highwayBlurRamp(scale = 1): ExpressionSpecification {
  const expr: unknown[] = ['interpolate', ['linear'], ['zoom']]
  for (const { zoom, mm } of HIGHWAY_INNER_BLUR_MM) {
    expr.push(zoom, mmToPixels(mm) * scale)
  }
  return expr as ExpressionSpecification
}

/**
 * Soft drop shadow under a polygon fill: translated fill + blurred outline.
 * Insert *before* the main fill in the style array.
 */
export function dropShadow(
  idPrefix: string,
  base: LayerBase,
  options: DropShadowOptions,
): LayerSpecification[] {
  const { blurM, offsetM, angleDeg, color, opacity, lat = DEFAULT_LAT } = options
  const translate = metreOffsetTranslate(offsetM, angleDeg, lat)
  const width = metresInterpolate(blurM, 1, lat)
  const blur = width

  const fill: FillLayerSpecification = {
    id: `${idPrefix}-drop-fill`,
    type: 'fill',
    ...base,
    paint: {
      'fill-color': color,
      'fill-opacity': opacity,
      'fill-translate': translate,
      'fill-translate-anchor': 'map',
    },
  }

  const outline: LineLayerSpecification = {
    id: `${idPrefix}-drop-blur`,
    type: 'line',
    ...base,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': color,
      'line-opacity': opacity,
      'line-width': width,
      'line-blur': blur,
      'line-translate': translate,
      'line-translate-anchor': 'map',
    },
  }

  return [fill, outline]
}

/**
 * Inward soft edge on a polygon: negative line-offset (~ half width) + line-blur.
 */
export function innerShadow(
  idPrefix: string,
  base: LayerBase,
  options: InnerShadowOptions,
): LayerSpecification[] {
  const lat = options.lat ?? DEFAULT_LAT
  const widthM = options.widthM ?? options.blurM
  const width = metresInterpolate(widthM, 1, lat)
  const blur = metresInterpolate(options.blurM, 1, lat)
  const offset = metresInterpolate(widthM, -0.5, lat)

  const line: LineLayerSpecification = {
    id: `${idPrefix}-inner`,
    type: 'line',
    ...base,
    layout: { 'line-cap': 'butt', 'line-join': 'round' },
    paint: {
      'line-color': options.color,
      'line-opacity': options.opacity ?? 1,
      'line-width': width,
      'line-blur': blur,
      'line-offset': offset,
    },
  }

  return [line]
}

/**
 * Two stacked blurred outlines (outer then inner), colour slightly lighter than the fill.
 */
export function outerGlow(
  idPrefix: string,
  base: LayerBase,
  options: OuterGlowOptions,
): LayerSpecification[] {
  const lat = options.lat ?? DEFAULT_LAT
  const factor = options.outerWidthFactor ?? 2
  const width = metresInterpolate(options.blurM, 1, lat)
  const blur = width
  const outerWidth = metresInterpolate(options.blurM, factor, lat)
  const outerBlur = outerWidth

  const inner: LineLayerSpecification = {
    id: `${idPrefix}-glow-inner`,
    type: 'line',
    ...base,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': options.color,
      'line-opacity': options.opacityInner ?? 0.45,
      'line-width': width,
      'line-blur': blur,
    },
  }

  const outer: LineLayerSpecification = {
    id: `${idPrefix}-glow-outer`,
    type: 'line',
    ...base,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': options.color,
      'line-opacity': options.opacityOuter ?? 0.25,
      'line-width': outerWidth,
      'line-blur': outerBlur,
    },
  }

  return [outer, inner]
}

/**
 * Two stacked inward soft glows (wider outer then narrower inner).
 * Same matched width/blur as outerGlow, with negative line-offset.
 */
export function innerGlow(
  idPrefix: string,
  base: LayerBase,
  options: InnerGlowOptions,
): LayerSpecification[] {
  const lat = options.lat ?? DEFAULT_LAT
  const factor = options.outerWidthFactor ?? 2
  const width = metresInterpolate(options.blurM, 1, lat)
  const blur = width
  const outerWidth = metresInterpolate(options.blurM, factor, lat)
  const outerBlur = outerWidth
  const offset = metresInterpolate(options.blurM, -0.5, lat)
  const outerOffset = metresInterpolate(options.blurM, -0.5 * factor, lat)

  const outer: LineLayerSpecification = {
    id: `${idPrefix}-glow-outer`,
    type: 'line',
    ...base,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': options.color,
      'line-opacity': options.opacityOuter ?? 0.25,
      'line-width': outerWidth,
      'line-blur': outerBlur,
      'line-offset': outerOffset,
    },
  }

  const inner: LineLayerSpecification = {
    id: `${idPrefix}-glow-inner`,
    type: 'line',
    ...base,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': options.color,
      'line-opacity': options.opacityInner ?? 0.45,
      'line-width': width,
      'line-blur': blur,
      'line-offset': offset,
    },
  }

  return [outer, inner]
}

/**
 * QGIS z14–z20 highway innerShadow blur radii (MM paper units).
 * Collapses seven one-zoom QGIS layers into one interpolate (docs G4).
 */
export const HIGHWAY_INNER_BLUR_MM: ReadonlyArray<{ zoom: number; mm: number }> = [
  { zoom: 14, mm: 0.2 },
  { zoom: 15, mm: 0.29 },
  { zoom: 16, mm: 0.4 },
  { zoom: 17, mm: 0.57 },
  { zoom: 18, mm: 0.8 },
  { zoom: 19, mm: 1.13 },
  { zoom: 20, mm: 1.6 },
]

/**
 * Inward soft carriageway edge: matched line-width/line-blur from HIGHWAY_INNER_BLUR_MM
 * plus negative line-offset (half width). Default colour/opacity match QGIS.
 */
export function highwayInnerBlur(
  idPrefix: string,
  base: LayerBase,
  options: HighwayInnerBlurOptions = {},
): LayerSpecification[] {
  const width = highwayBlurRamp(1)
  const blur = width
  const offset = highwayBlurRamp(-0.5)

  const line: LineLayerSpecification = {
    id: idPrefix,
    type: 'line',
    ...base,
    layout: { 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': options.color ?? '#232323',
      'line-opacity': options.opacity ?? 0.67,
      'line-width': width,
      'line-blur': blur,
      'line-offset': offset,
    },
  }

  return [line]
}
