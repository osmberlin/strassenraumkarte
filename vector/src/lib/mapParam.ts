/**
 * Viewport URL param `map=zoom/lat/lng` (FMC / tanstack-router-conventions).
 * Readable slashes — never encodeURIComponent the serialized value.
 */

export type MapParam = { zoom: number; lat: number; lng: number }

/** Berlin-Neukölln starter area (matches style/basic DEFAULT_VIEW). */
export const mapParamFallback: MapParam = {
  lat: 52.4768,
  lng: 13.4222,
  zoom: 16,
}

function roundNumber(number: number, precision: number): number {
  return Number.parseFloat(number.toFixed(precision))
}

function roundByZoom(number: number, zoom: number): number {
  const precision = zoom >= 17 ? 5 : zoom < 13 ? 3 : 4
  return roundNumber(number, precision)
}

/** Round lat/lng/zoom for stable share URLs (precision grows with zoom). */
export function roundPositionForURL(
  lat: number,
  lng: number,
  zoom: number,
): readonly [number, number, number] {
  return [roundByZoom(lat, zoom), roundByZoom(lng, zoom), roundNumber(zoom, 1)] as const
}

export function parseMapParam(query: string | null | undefined): MapParam | null {
  if (!query) return null
  const parts = query.split('/')
  if (parts.length !== 3) return null
  const zoom = Number(parts[0])
  const lat = Number(parts[1])
  const lng = Number(parts[2])
  if (!Number.isFinite(zoom) || zoom < 0 || zoom > 22) return null
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) return null
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) return null
  return { zoom, lat, lng }
}

export function serializeMapParam({ zoom, lat, lng }: MapParam): string {
  const [roundedLat, roundedLng, roundedZoom] = roundPositionForURL(lat, lng, zoom)
  return `${roundedZoom}/${roundedLat}/${roundedLng}`
}
