import type { FilterSpecification, LayerSpecification } from '@maplibre/maplibre-gl-style-spec'

import { HIGHWAY_BLUR, SERVICE_LINE, TACTILE } from '../colors'
import { HIGHWAY_INNER_BLUR_MM } from '../effects'
import { highwayAreaFillMatch, withOsmBucket } from '../expr'
import { mmToPixels } from '../metres'
import { metresToPixels, metresToPixelsFromProp } from '../metres'
import { OSM_LAYER_BUCKETS, styleLayerId } from '../order'

/** Collapsed z14–z20 highway edge blur (MM paper units → px). */
function highwayBlurPx(): unknown[] {
  const expr: unknown[] = ['interpolate', ['linear'], ['zoom']]
  for (const { zoom, mm } of HIGHWAY_INNER_BLUR_MM) {
    expr.push(zoom, mmToPixels(mm))
  }
  return expr
}

/** Streets: per OSM layer bucket — service → tactile → highway_area + blur. */
export function streetLayers(): LayerSpecification[] {
  const layers: LayerSpecification[] = []
  const blurRamp = highwayBlurPx()

  for (const bucket of OSM_LAYER_BUCKETS) {
    const serviceBase = withOsmBucket('highway_service', 15, bucket.id)
    layers.push({
      id: styleLayerId('highway_service', 'line', bucket.id),
      type: 'line',
      ...serviceBase,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': SERVICE_LINE,
        'line-width': metresToPixelsFromProp('width', 3.5),
      },
    })

    const tactileBase = withOsmBucket('tactile_paving', 17, bucket.id)
    layers.push({
      id: styleLayerId('tactile_paving', 'line', bucket.id),
      type: 'line',
      ...tactileBase,
      layout: { 'line-cap': 'butt', 'line-join': 'round' },
      paint: {
        'line-color': TACTILE,
        'line-width': metresToPixels(1),
        'line-offset': metresToPixels(-0.5),
      },
    })

    const areaBase = withOsmBucket('highway_area', 15, bucket.id)
    layers.push({
      id: styleLayerId('highway_area', 'fill', bucket.id),
      type: 'fill',
      ...areaBase,
      paint: {
        'fill-color': highwayAreaFillMatch(),
        'fill-opacity': 1,
      },
    })

    layers.push({
      id: styleLayerId('highway_area', 'blur', bucket.id),
      type: 'line',
      ...areaBase,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: {
        'line-color': HIGHWAY_BLUR,
        'line-opacity': 0.85,
        'line-width': blurRamp as never,
        'line-blur': blurRamp as never,
      },
    })

    // Surface textures from the packed sprite (w5). Rotation/scale approximations deferred.
    for (const [surface, pattern, opacity] of [
      ['asphalt', 'surface/asphalt', 0.06],
      ['concrete', 'surface/concrete', 0.35],
      ['concrete:plates', 'surface/concrete', 0.35],
      ['paving_stones', 'surface/paving_stones', 0.1],
      ['sett', 'surface/sett', 0.12],
    ] as const) {
      layers.push({
        id: styleLayerId('highway_area', `pattern-${surface.replace(':', '-')}`, bucket.id),
        type: 'fill',
        ...withOsmBucket('highway_area', 15, bucket.id, ['==', ['get', 'surface'], surface]),
        paint: {
          'fill-pattern': pattern,
          'fill-opacity': opacity,
        },
      })
    }
  }

  return layers
}

/** Combine optional extra filter (unused helper for future surface rules). */
export function allFilters(...parts: FilterSpecification[]): FilterSpecification {
  return ['all', ...parts] as FilterSpecification
}
