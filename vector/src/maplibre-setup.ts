/**
 * MapLibre GL JS v6 + Vite setup per
 * https://maplibre.org/maplibre-gl-js/docs/guides/v5-to-v6-migration-guide/
 * and the install guide (`?worker&url` + setWorkerUrl).
 */
import { Protocol } from 'pmtiles'
import { addProtocol, setWorkerUrl } from 'maplibre-gl'
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'

setWorkerUrl(workerUrl)

const protocol = new Protocol({ metadata: true })
// Bind so Protocol.tile keeps `this`.
addProtocol('pmtiles', (request, abortController) => protocol.tile(request, abortController))

export function pmtilesSourceUrl(archivePath = '/tiles/strassenraumkarte.pmtiles'): string {
  const absolute = new URL(archivePath, window.location.origin).href
  return `pmtiles://${absolute}`
}
