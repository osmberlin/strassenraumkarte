import { useCallback, useEffect, useMemo, useState } from 'react'
import type { LayerSpecification, MapLibreEvent } from 'maplibre-gl'
import type { ViewStateChangeEvent } from 'react-map-gl/maplibre'
import {
  Layer,
  Map,
  MapProvider,
  NavigationControl,
  ScaleControl,
  Source,
} from 'react-map-gl/maplibre'
import 'maplibre-gl/dist/maplibre-gl.css'

import { LAYERS, MAP_MAX_ZOOM, MAP_MIN_ZOOM, SOURCE_MAXZOOM, SOURCE_MINZOOM } from '../layers'
import {
  findLocation,
  modeById,
  panesFromParam,
  panesToParam,
  type CompareMode,
  type ComparePanes,
} from '../locations'
import { ComparePage } from './compare/ComparePage'
import { Legend } from './components/Legend'
import { exposeMainMapForDebugging } from './lib/expose-main-map'
import {
  mapParamFallback,
  parseMapParam,
  serializeMapParam,
  type MapParam,
} from './lib/mapParam'
import { installMissingStyleImageResolver } from './lib/missing-style-images'
import { mapLib, pmtilesSourceUrl } from './maplibre-setup'
import { emptyBaseStyle } from './style/build-style'
import { basicLayerSpecs } from './style/basic'
import { SOURCE_ID, spriteSources } from './style/source'
import {
  legendEntries,
  layerMatchesLegend,
  PREP_COLORS,
  type LegendEntry,
} from './style/legend'
import { qgisLayerSpecs } from './style/qgis'

const MAP_ID = 'mainMap'
const qgisLayers = qgisLayerSpecs() as LayerSpecification[]
const debugLayers = basicLayerSpecs() as LayerSpecification[]
const qgisLegend = legendEntries()
const BASE_STYLE = emptyBaseStyle({
  name: 'Straßenraumkarte vector',
  sprite: spriteSources(window.location.origin),
})

/** Cartographic QGIS port vs blue/purple/red tile-contents debug style. */
export type StyleMode = 'qgis' | 'debug'

type RouteState = {
  compare: boolean
  location: string
  mode: CompareMode
  panes: ComparePanes
  style: StyleMode
  map: MapParam
}

function styleModeFromParam(raw: string | null): StyleMode {
  return raw === 'debug' || raw === 'basic' || raw === 'prep' ? 'debug' : 'qgis'
}

/** One legend row per tippecanoe source-layer (debug / prep paints). */
function debugLegendEntries(): LegendEntry[] {
  return LAYERS.map((def) => ({
    id: def.id,
    label: def.id,
    group: def.group,
    kind: def.paint,
    color:
      def.paint === 'fill'
        ? PREP_COLORS.fill
        : def.paint === 'line'
          ? PREP_COLORS.line
          : PREP_COLORS.circle,
    minzoom: def.minzoom,
    maxzoom: def.maxzoom,
    layerIds: [`${def.id}-${def.paint}`],
  }))
}

const debugLegend = debugLegendEntries()

function mapFallbackForRoute(compare: boolean, locationId: string): MapParam {
  if (!compare) return mapParamFallback
  const loc = findLocation(locationId)
  if (!loc) return mapParamFallback
  return { zoom: loc.zoom, lat: loc.latitude, lng: loc.longitude }
}

function readRoute(): RouteState {
  const q = new URLSearchParams(window.location.search)
  const compare = q.get('compare') === '1' || q.get('view') === 'compare'
  const location = findLocation(q.get('location'))?.id ?? ''
  const map =
    parseMapParam(q.get('map')) ?? mapFallbackForRoute(compare, location)
  return {
    compare,
    location,
    mode: modeById(q.get('mode')),
    panes: panesFromParam(q.get('panes')),
    style: styleModeFromParam(q.get('style')),
    map,
  }
}

/**
 * Build search string with literal `/` in `map=` (URLSearchParams would use %2F).
 * Matches tanstack-router pretty search serialization for this param.
 */
function writeRoute(next: RouteState) {
  const parts: string[] = []
  if (next.compare) {
    parts.push('compare=1')
    if (next.location) {
      parts.push(`location=${encodeURIComponent(next.location)}`)
    }
    parts.push(`mode=${encodeURIComponent(next.mode)}`)
    parts.push(`panes=${encodeURIComponent(panesToParam(next.panes))}`)
  }
  if (next.style === 'debug') parts.push('style=debug')
  parts.push(`map=${serializeMapParam(next.map)}`)
  const qs = parts.join('&')
  const nextUrl = `${window.location.pathname}${qs ? `?${qs}` : ''}${window.location.hash}`
  const cur = `${window.location.pathname}${window.location.search}${window.location.hash}`
  if (nextUrl !== cur) {
    window.history.replaceState(null, '', nextUrl)
  }
}

function MapCanvas({
  map,
  onMap,
  onStatus,
  onError,
  onZoom,
  hidden,
  styleMode,
  legend,
  layers,
}: {
  map: MapParam
  onMap: (map: MapParam) => void
  onStatus: (s: string) => void
  onError: (s: string | null) => void
  onZoom: (z: number) => void
  hidden: ReadonlySet<string>
  styleMode: StyleMode
  legend: LegendEntry[]
  layers: LayerSpecification[]
}) {
  const [layersReady, setLayersReady] = useState(false)

  const handleLoad = useCallback(
    (event: MapLibreEvent) => {
      const mapInst = event.target
      exposeMainMapForDebugging(mapInst)
      installMissingStyleImageResolver(mapInst)
      setLayersReady(true)
      onZoom(mapInst.getZoom())
      onStatus(styleMode === 'debug' ? 'Map loaded (debug tile style)' : 'Map loaded')
      onError(null)
    },
    [onError, onStatus, onZoom, styleMode],
  )

  const handleIdle = useCallback(
    (event: MapLibreEvent) => {
      const mapInst = event.target
      onZoom(mapInst.getZoom())
      const tag = styleMode === 'debug' ? 'debug · ' : ''
      onStatus(
        `idle · ${tag}z${mapInst.getZoom().toFixed(1)} · ${mapInst.getCenter().lng.toFixed(5)}, ${mapInst.getCenter().lat.toFixed(5)}`,
      )
    },
    [onStatus, onZoom, styleMode],
  )

  const writeMapParam = useCallback(
    (event: ViewStateChangeEvent) => {
      const { latitude, longitude, zoom } = event.viewState
      onZoom(zoom)
      onMap({
        zoom: Math.min(MAP_MAX_ZOOM, Math.max(MAP_MIN_ZOOM, zoom)),
        lat: latitude,
        lng: longitude,
      })
    },
    [onMap, onZoom],
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
    return layers.filter((layer) => {
      const hiddenBy = [...hidden].some((legendId) => {
        const entry = legend.find((e) => e.id === legendId)
        if (!entry) return false
        if (styleMode === 'debug') {
          return (
            layer.id === `${entry.id}-fill` ||
            layer.id === `${entry.id}-line` ||
            layer.id === `${entry.id}-circle`
          )
        }
        return layerMatchesLegend(layer.id, entry)
      })
      return !hiddenBy
    })
  }, [hidden, layers, legend, styleMode])

  return (
    <Map
      mapLib={mapLib}
      id={MAP_ID}
      style={{ width: '100%', height: '100%' }}
      mapStyle={BASE_STYLE}
      initialViewState={{
        longitude: map.lng,
        latitude: map.lat,
        zoom: map.zoom,
      }}
      minZoom={MAP_MIN_ZOOM}
      maxZoom={MAP_MAX_ZOOM}
      attributionControl={false}
      onLoad={handleLoad}
      onIdle={handleIdle}
      onMoveEnd={writeMapParam}
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
          <Layer key={`${styleMode}:${layer.id}`} {...(layer as any)} />
        ))}
    </Map>
  )
}

export function App() {
  const [route, setRoute] = useState(readRoute)
  const [status, setStatus] = useState('Starting…')
  const [error, setError] = useState<string | null>(null)
  const [zoom, setZoom] = useState<number>(() => route.map.zoom)
  const [hidden, setHidden] = useState<ReadonlySet<string>>(() => new Set())

  const styleMode = route.style
  const activeLegend = styleMode === 'debug' ? debugLegend : qgisLegend
  const activeLayers = styleMode === 'debug' ? debugLayers : qgisLayers

  useEffect(() => {
    writeRoute(route)
  }, [route])

  // Reset layer visibility when switching style modes (ids differ).
  useEffect(() => {
    setHidden(new Set())
  }, [styleMode])

  const setMap = useCallback((map: MapParam) => {
    setRoute((r) => ({ ...r, map }))
  }, [])

  const toggle = useCallback((legendId: string) => {
    setHidden((prev) => {
      const next = new Set(prev)
      if (next.has(legendId)) next.delete(legendId)
      else next.add(legendId)
      return next
    })
  }, [])

  const showAll = useCallback(() => setHidden(new Set()), [])
  const hideAll = useCallback(
    () => setHidden(new Set(activeLegend.map((e) => e.id))),
    [activeLegend],
  )

  if (route.compare) {
    return (
      <MapProvider>
        <ComparePage
          locationId={route.location}
          mode={route.mode}
          panes={route.panes}
          map={route.map}
          onMap={setMap}
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
          <label className="style-toggle">
            <input
              type="checkbox"
              checked={styleMode === 'debug'}
              onChange={(e) =>
                setRoute((r) => ({
                  ...r,
                  style: e.target.checked ? 'debug' : 'qgis',
                }))
              }
            />
            Debug tile style
          </label>
          <button
            type="button"
            className="legend-btn"
            onClick={() => setRoute((r) => ({ ...r, compare: true }))}
          >
            Compare QGIS · Rust · Vector
          </button>
          <span className="muted">
            {styleMode === 'debug'
              ? 'Blue fills · purple lines · red points — one layer per source-layer'
              : 'QGIS-faithful core paints'}{' '}
            · <code>?style=debug</code>
          </span>
          <span className={error ? 'err' : 'ok'}>{error ?? status}</span>
        </header>
        <div className="workspace">
          <Legend
            entries={activeLegend}
            zoom={zoom}
            hidden={hidden}
            onToggle={toggle}
            onShowAll={showAll}
            onHideAll={hideAll}
          />
          <div className="map">
            <MapCanvas
              map={route.map}
              onMap={setMap}
              onStatus={setStatus}
              onError={setError}
              onZoom={setZoom}
              hidden={hidden}
              styleMode={styleMode}
              legend={activeLegend}
              layers={activeLayers}
            />
          </div>
        </div>
      </div>
    </MapProvider>
  )
}
