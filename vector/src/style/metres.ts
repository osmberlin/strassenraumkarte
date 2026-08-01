/**
 * Ground metres → MapLibre CSS pixels (512 px Web Mercator tiles).
 *
 * px = m * 2^z / (78271.51696 * cos φ)
 *
 * That is exactly base-2 exponential in zoom, so a two-stop interpolate is exact
 * (same role as QGIS `@mercator_scale` on MapUnit sizes). Default φ = Berlin.
 *
 * Paper units (MM / Point) must NOT go through this helper — use `mmToPixels`.
 */
import type { ExpressionSpecification } from '@maplibre/maplibre-gl-style-spec'

/** Neukölln / Berlin reference latitude used by the raster pipeline. */
export const DEFAULT_LAT = 52.48

/** Metres of ground covered by one CSS pixel at zoom 0 on the equator (Web Mercator, 512). */
export const METRES_PER_PIXEL_Z0 = 78271.51696

export type MetresInput = number | ExpressionSpecification

function metresFactorAtZoom(zoom: number, lat: number): number {
  return 2 ** zoom / (METRES_PER_PIXEL_Z0 * Math.cos((lat * Math.PI) / 180))
}

function scaleMetres(m: MetresInput, factor: number): number | ExpressionSpecification {
  if (typeof m === 'number') return m * factor
  return ['*', m, factor] as ExpressionSpecification
}

/**
 * Exact zoom interpolate for a ground-metre width/size/offset.
 * Stops at z15 and z20 match the Straßenraumkarte camera range.
 */
export function metresToPixels(
  m: MetresInput,
  lat: number = DEFAULT_LAT,
): ExpressionSpecification {
  const z15 = metresFactorAtZoom(15, lat)
  const z20 = metresFactorAtZoom(20, lat)
  return [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    15,
    scaleMetres(m, z15),
    20,
    scaleMetres(m, z20),
  ] as ExpressionSpecification
}

/** Pixel factor at a single zoom (tests / one-off calcs). */
export function metresToPixelsAtZoom(m: number, zoom: number, lat: number = DEFAULT_LAT): number {
  return m * metresFactorAtZoom(zoom, lat)
}

/**
 * QGIS millimetres (paper) → CSS pixels at 96 DPI.
 * Used for the z14–z20 highway blur radii and other MM-sized effect params.
 */
export function mmToPixels(mm: number): number {
  return (mm / 25.4) * 96
}
