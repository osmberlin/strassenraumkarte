import { useEffect, useRef, useState } from 'react'
import {
  Map as MapLibreMap,
  NavigationControl,
  ScaleControl,
  setWorkerUrl,
} from 'maplibre-gl'
import maplibreWorkerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url'
import 'maplibre-gl/dist/maplibre-gl.css'

import { DEFAULT_VIEW, buildBasicStyle } from './style/basic'

// Vite prebundle breaks the default worker URL; pin the packaged worker explicitly.
setWorkerUrl(maplibreWorkerUrl)

export function App() {
  const containerRef = useRef<HTMLDivElement>(null)
  const [status, setStatus] = useState('Starting…')
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const el = containerRef.current
    if (!el) return

    // HTTP MVT from Vite middleware (MapLibre 6 workers cannot use addProtocol('pmtiles')).
    const tileTemplate = `${window.location.origin}/mvt/{z}/{x}/{y}.mvt`
    const style = buildBasicStyle(tileTemplate)

    const map = new MapLibreMap({
      container: el,
      style,
      center: [DEFAULT_VIEW.longitude, DEFAULT_VIEW.latitude],
      zoom: DEFAULT_VIEW.zoom,
      minZoom: 14,
      maxZoom: 20,
      hash: true,
    })
    ;(window as unknown as { __srkMap?: unknown }).__srkMap = map

    map.addControl(new NavigationControl(), 'top-right')
    map.addControl(new ScaleControl({ unit: 'metric' }), 'bottom-left')

    map.on('load', () => setStatus('Map loaded'))
    map.on('idle', () => {
      setStatus(
        `idle · z${map.getZoom().toFixed(1)} · ${map.getCenter().lng.toFixed(5)}, ${map.getCenter().lat.toFixed(5)}`,
      )
    })
    map.on('error', (e) => {
      const msg = e.error?.message ?? String(e.error ?? 'unknown map error')
      console.error('[map error]', e)
      setError(msg)
    })
    const hang = window.setTimeout(() => {
      setStatus((s) => (s === 'Starting…' ? 'Still starting (check /mvt tiles)' : s))
    }, 4000)

    return () => {
      window.clearTimeout(hang)
      map.remove()
    }
  }, [])

  return (
    <div className="app">
      <header className="bar">
        <strong>Straßenraumkarte · vector preview</strong>
        <span className="muted">
          areas blue · lines purple · points red ·{' '}
          <code>/mvt/&#123;z&#125;/&#123;x&#125;/&#123;y&#125;.mvt</code>
        </span>
        <span className={error ? 'err' : 'ok'}>{error ?? status}</span>
      </header>
      <div ref={containerRef} className="map" />
    </div>
  )
}
