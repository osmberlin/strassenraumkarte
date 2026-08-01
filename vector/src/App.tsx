import { useCallback, useState } from 'react'
import type { MapLibreEvent } from 'maplibre-gl'
import {
  Layer,
  Map,
  MapProvider,
  NavigationControl,
  ScaleControl,
  Source,
} from 'react-map-gl/maplibre'
import 'maplibre-gl/dist/maplibre-gl.css'

import {
  MAP_MAX_ZOOM,
  MAP_MIN_ZOOM,
  SOURCE_MAXZOOM,
  SOURCE_MINZOOM,
} from '../layers'
import { exposeMainMapForDebugging } from './lib/expose-main-map'
import { pmtilesSourceUrl } from './maplibre-setup'
import { BASE_STYLE, DEFAULT_VIEW, SOURCE_ID, basicLayerSpecs } from './style/basic'

const MAP_ID = 'mainMap'
const layers = basicLayerSpecs()

function MapCanvas({
  onStatus,
  onError,
}: {
  onStatus: (s: string) => void
  onError: (s: string | null) => void
}) {
  const handleLoad = useCallback(
    (event: MapLibreEvent) => {
      exposeMainMapForDebugging(event.target)
      onStatus('Map loaded')
      onError(null)
    },
    [onError, onStatus],
  )

  const handleIdle = useCallback(
    (event: MapLibreEvent) => {
      const map = event.target
      onStatus(
        `idle · z${map.getZoom().toFixed(1)} · ${map.getCenter().lng.toFixed(5)}, ${map.getCenter().lat.toFixed(5)}`,
      )
    },
    [onStatus],
  )

  const handleError = useCallback(
    (event: { error?: Error }) => {
      const msg = event.error?.message ?? String(event.error ?? 'unknown map error')
      console.error('[map error]', event)
      onError(msg)
    },
    [onError],
  )

  return (
    <Map
      id={MAP_ID}
      style={{ width: '100%', height: '100%' }}
      mapStyle={BASE_STYLE}
      initialViewState={{
        longitude: DEFAULT_VIEW.longitude,
        latitude: DEFAULT_VIEW.latitude,
        zoom: DEFAULT_VIEW.zoom,
      }}
      minZoom={MAP_MIN_ZOOM}
      maxZoom={MAP_MAX_ZOOM}
      hash
      attributionControl={false}
      onLoad={handleLoad}
      onIdle={handleIdle}
      onError={handleError}
    >
      <NavigationControl position="top-right" />
      <ScaleControl position="bottom-left" unit="metric" />

      {/*
        Source min/maxzoom = PMTiles archive (tippecanoe), not MAP_MAX_ZOOM.
        At map z19–20 MapLibre overscales z18 tiles; raising source maxzoom would 404.
      */}
      <Source
        id={SOURCE_ID}
        type="vector"
        url={pmtilesSourceUrl()}
        minzoom={SOURCE_MINZOOM}
        maxzoom={SOURCE_MAXZOOM}
      />
      {layers.map((layer) => (
        <Layer key={layer.id} {...layer} />
      ))}
    </Map>
  )
}

export function App() {
  const [status, setStatus] = useState('Starting…')
  const [error, setError] = useState<string | null>(null)

  return (
    <MapProvider>
      <div className="app">
        <header className="bar">
          <strong>Straßenraumkarte · vector preview</strong>
          <span className="muted">
            areas blue · lines purple · points red ·{' '}
            <code>pmtiles://…/strassenraumkarte.pmtiles</code>
          </span>
          <span className={error ? 'err' : 'ok'}>{error ?? status}</span>
        </header>
        <div className="map">
          <MapCanvas onStatus={setStatus} onError={setError} />
        </div>
      </div>
    </MapProvider>
  )
}
