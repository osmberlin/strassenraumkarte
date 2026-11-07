import type { Map as MaplibreMap } from 'maplibre-gl'

declare global {
  interface Window {
    __mainMap?: MaplibreMap
    __srkMap?: MaplibreMap
  }
}

/** Expose MapLibre instance for Playwright / agent inspection (dev only). */
export function exposeMainMapForDebugging(map: MaplibreMap) {
  if (!import.meta.env.DEV) return
  window.__mainMap = map
  // Keep legacy alias used by early verify scripts.
  window.__srkMap = map
}
