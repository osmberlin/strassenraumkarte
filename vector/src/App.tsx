import { useCallback, useEffect, useMemo, useState } from 'react'
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
import { locationById, modeById, panesFromParam, panesToParam, type CompareMode, type ComparePanes } from '../locations'
import { ComparePage } from './compare/ComparePage'
import { Legend } from './components/Legend'
import { exposeMainMapForDebugging } from './lib/expose-main-map'
import { installMissingStyleImageResolver } from './lib/missing-style-images'
import { pmtilesSourceUrl } from './maplibre-setup'
import { emptyBaseStyle } from './style/build-style'
import { DEFAULT_VIEW } from './style/basic'
import { SOURCE_ID, absoluteSpriteUrl } from './style/source'
import { legendEntries, layerMatchesLegend } from './style/legend'
import { qgisLayerSpecs } from './style/qgis'

const MAP_ID = 'mainMap'
const allLayers = qgisLayerSpecs() as LayerSpecification[]
const legend = legendEntries()
const BASE_STYLE = emptyBaseStyle({
  name: 'Straßenraumkarte vector',
  sprite: absoluteSpriteUrl(window.location.origin),
})

function readRoute(): {
  compare: boolean
  location: string
  mode: CompareMode
  panes: ComparePanes
} {
  const q = new URLSearchParams(window.location.search)
  return {
    compare: q.get('compare') === '1' || q.get('view') === 'compare',
    location: locationById(q.get('location')).id,
    mode: modeById(q.get('mode')),
    panes: panesFromParam(q.get('panes')),
  }
}

function writeRoute(next: {
  compare: boolean
  location: string
  mode: CompareMode
  panes: ComparePanes
}) {
  const url = new URL(window.location.href)
  if (next.compare) {
    url.searchParams.set('compare', '1')
    url.searchParams.set('location', next.location)
    url.searchParams.set('mode', next.mode)
    url.searchParams.set('panes', panesToParam(next.panes))
  } else {
    url.searchParams.delete('compare')
    url.searchParams.delete('view')
    url.searchParams.delete('location')
    url.searchParams.delete('mode')
    url.searchParams.delete('panes')
  }
  window.history.replaceState(null, '', url.toString())
}

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
  const [layersReady, setLayersReady] = useState(false)

  const handleLoad = useCallback(
    (event: MapLibreEvent) => {
      const map = event.target
      exposeMainMapForDebugging(map)
      installMissingStyleImageResolver(map)
      setLayersReady(true)
      onZoom(map.getZoom())
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
      {layersReady &&
        visibleLayers.map((layer) => (
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          <Layer key={layer.id} {...(layer as any)} />
        ))}
    </Map>
  )
}

export function App() {
  const [route, setRoute] = useState(readRoute)
  const [status, setStatus] = useState('Starting…')
  const [error, setError] = useState<string | null>(null)
  const [zoom, setZoom] = useState<number>(DEFAULT_VIEW.zoom)
  const [hidden, setHidden] = useState<ReadonlySet<string>>(() => new Set())

  useEffect(() => {
    writeRoute(route)
  }, [route])

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

  if (route.compare) {
    return (
      <MapProvider>
        <ComparePage
          locationId={route.location}
          mode={route.mode}
          panes={route.panes}
          onLocation={(location) => setRoute((r) => ({ ...r, location }))}
          onMode={(mode) => setRoute((r) => ({ ...r, mode }))}
          onPanes={(panes) => setRoute((r) => ({ ...r, panes }))}
          onBack={() => setRoute((r) => ({ ...r, compare: false }))}
        />
      </MapProvider>
    )
  }

  return (
    <MapProvider>
      <div className="app">
        <header className="bar">
          <strong>Straßenraumkarte · vector preview</strong>
          <button
            type="button"
            className="legend-btn"
            onClick={() => setRoute((r) => ({ ...r, compare: true }))}
          >
            Compare QGIS · Rust · Vector
          </button>
          <span className="muted">
            QGIS-faithful core paints ·{' '}
            <code>?compare=1&amp;location=&amp;mode=</code>
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
