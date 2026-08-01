import { useCallback, useMemo, useState } from 'react'
import type { LayerSpecification, MapLibreEvent } from 'maplibre-gl'
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
import { Legend } from './components/Legend'
import { exposeMainMapForDebugging } from './lib/expose-main-map'
import { pmtilesSourceUrl } from './maplibre-setup'
import { emptyBaseStyle } from './style/build-style'
import { DEFAULT_VIEW } from './style/basic'
import { SOURCE_ID } from './style/source'
import { legendEntries, layerMatchesLegend } from './style/legend'
import { qgisLayerSpecs } from './style/qgis'

const MAP_ID = 'mainMap'
const allLayers = qgisLayerSpecs() as LayerSpecification[]
const legend = legendEntries()
const BASE_STYLE = emptyBaseStyle({ name: 'Straßenraumkarte vector' })

function MapCanvas({
  onStatus,
  onError,
  onZoom,
  hidden,
}: {
  onStatus: (s: string) => void
  onError: (s: string | null) => void
  onZoom: (z: number) => void
  hidden: ReadonlySet<string>
}) {
  const handleLoad = useCallback(
    (event: MapLibreEvent) => {
      exposeMainMapForDebugging(event.target)
      onZoom(event.target.getZoom())
      onStatus('Map loaded')
      onError(null)
    },
    [onError, onStatus, onZoom],
  )

  const handleIdle = useCallback(
    (event: MapLibreEvent) => {
      const map = event.target
      onZoom(map.getZoom())
      onStatus(
        `idle · z${map.getZoom().toFixed(1)} · ${map.getCenter().lng.toFixed(5)}, ${map.getCenter().lat.toFixed(5)}`,
      )
    },
    [onStatus, onZoom],
  )

  const handleMove = useCallback(
    (event: MapLibreEvent) => {
      onZoom(event.target.getZoom())
    },
    [onZoom],
  )

  const handleError = useCallback(
    (event: { error?: Error }) => {
      const msg = event.error?.message ?? String(event.error ?? 'unknown map error')
      console.error('[map error]', event)
      onError(msg)
    },
    [onError],
  )

  const visibleLayers = useMemo(() => {
    return allLayers.filter((layer) => {
      const hiddenBy = [...hidden].some((legendId) => {
        const entry = legend.find((e) => e.id === legendId)
        return entry ? layerMatchesLegend(layer.id, entry) : false
      })
      return !hiddenBy
    })
  }, [hidden])

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
      onMove={handleMove}
      onError={handleError}
    >
      <NavigationControl position="top-right" />
      <ScaleControl position="bottom-right" unit="metric" />

      <Source
        id={SOURCE_ID}
        type="vector"
        url={pmtilesSourceUrl()}
        minzoom={SOURCE_MINZOOM}
        maxzoom={SOURCE_MAXZOOM}
      />
      {visibleLayers.map((layer) => (
        // LayerSpecification → react-map-gl LayerProps (compatible at runtime).
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        <Layer key={layer.id} {...(layer as any)} />
      ))}
    </Map>
  )
}

export function App() {
  const [status, setStatus] = useState('Starting…')
  const [error, setError] = useState<string | null>(null)
  const [zoom, setZoom] = useState<number>(DEFAULT_VIEW.zoom)
  const [hidden, setHidden] = useState<ReadonlySet<string>>(() => new Set())

  const toggle = useCallback((legendId: string) => {
    setHidden((prev) => {
      const next = new Set(prev)
      if (next.has(legendId)) next.delete(legendId)
      else next.add(legendId)
      return next
    })
  }, [])

  const showAll = useCallback(() => setHidden(new Set()), [])
  const hideAll = useCallback(() => setHidden(new Set(legend.map((e) => e.id))), [])

  return (
    <MapProvider>
      <div className="app">
        <header className="bar">
          <strong>Straßenraumkarte · vector preview</strong>
          <span className="muted">
            QGIS-faithful core paints · hash keeps the view ·{' '}
            <code>pmtiles://…/strassenraumkarte.pmtiles</code>
          </span>
          <span className={error ? 'err' : 'ok'}>{error ?? status}</span>
        </header>
        <div className="workspace">
          <Legend
            entries={legend}
            zoom={zoom}
            hidden={hidden}
            onToggle={toggle}
            onShowAll={showAll}
            onHideAll={hideAll}
          />
          <div className="map">
            <MapCanvas
              onStatus={setStatus}
              onError={setError}
              onZoom={setZoom}
              hidden={hidden}
            />
          </div>
        </div>
      </div>
    </MapProvider>
  )
}
