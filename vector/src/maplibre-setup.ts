/**
 * MapLibre GL JS v6 + Vite setup per
 * https://maplibre.org/maplibre-gl-js/docs/guides/v5-to-v6-migration-guide/
 * and the install guide (`?worker&url` + setWorkerUrl).
 */
import { Protocol } from 'pmtiles'
import * as maplibregl from 'maplibre-gl'
// `-dev` worker: our bun patch points the `maplibre-gl` export at the unminified
// dev bundle (that is what the renderer patches edit) — the worker must match.
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker-dev.mjs?worker&url'

maplibregl.setWorkerUrl(workerUrl)

const protocol = new Protocol({ metadata: true })
// Bind so Protocol.tile keeps `this`.
maplibregl.addProtocol('pmtiles', (request, abortController) => protocol.tile(request, abortController))

export function pmtilesSourceUrl(archivePath = '/tiles/strassenraumkarte.pmtiles'): string {
  const absolute = new URL(archivePath, window.location.origin).href
  return `pmtiles://${absolute}`
}

/**
 * Pass as `<Map mapLib={mapLib}>`. Without it react-map-gl lazily imports its own
 * `maplibre-gl`, which Vite pre-bundles as a second copy — one that never saw
 * `addProtocol` / `setWorkerUrl` above.
 */
export const mapLib = maplibregl
