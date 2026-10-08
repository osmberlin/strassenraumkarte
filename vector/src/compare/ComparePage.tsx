import { useCallback, useMemo, useRef, useState } from 'react'
import type { Map as MaplibreMap, MapLibreEvent } from 'maplibre-gl'
import type { ViewStateChangeEvent } from 'react-map-gl/maplibre'
import {
  Layer,
  Map,
  NavigationControl,
  Source,
} from 'react-map-gl/maplibre'
import type { LayerSpecification } from 'maplibre-gl'

import {
  MAP_MAX_ZOOM,
  MAP_MIN_ZOOM,
  SOURCE_MAXZOOM,
  SOURCE_MINZOOM,
} from '../../layers'
import {
  COMPARE_LOCATIONS,
  COMPARE_MODES,
  COMPARE_PANES,
  findLocation,
  isNearCompareLocation,
  modeById,
  type CompareMode,
  type ComparePaneId,
  type ComparePanes,
} from '../../locations'
import type { MapParam } from '../lib/mapParam'
import { installMissingStyleImageResolver } from '../lib/missing-style-images'
import { mapLib, pmtilesSourceUrl } from '../maplibre-setup'
import { emptyBaseStyle } from '../style/build-style'
import { SOURCE_ID, spriteSources } from '../style/source'
import { qgisLayerSpecs } from '../style/qgis'

const RASTER_SOURCE = 'qgis-raster'
const RUST_RASTER_SOURCE = 'rust-raster'
const vectorLayers = qgisLayerSpecs() as LayerSpecification[]
const baseStyle = emptyBaseStyle({
  name: 'compare',
  sprite: spriteSources(window.location.origin),
})

type Props = {
  locationId: string
  mode: CompareMode
  panes: ComparePanes
  /** Viewport from `?map=zoom/lat/lng` — sole camera source of truth. */
  map: MapParam
  onMap: (map: MapParam) => void
  onLocation: (id: string) => void
  onMode: (mode: CompareMode) => void
  onPanes: (panes: ComparePanes) => void
  onBack: () => void
}

function clampMapFromEvent(e: ViewStateChangeEvent): MapParam {
  const { latitude, longitude, zoom } = e.viewState
  return {
    zoom: Math.min(MAP_MAX_ZOOM, Math.max(MAP_MIN_ZOOM, zoom)),
    lat: latitude,
    lng: longitude,
  }
}

export function ComparePage({
  locationId,
  mode,
  panes,
  map,
  onMap,
  onLocation,
  onMode,
  onPanes,
  onBack,
}: Props) {
  const location = findLocation(locationId)
  // Ephemeral controlled sync across panes; seeded from ?map= and written back on move end.
  const [view, setView] = useState<MapParam>(map)
  const [blend, setBlend] = useState(0.5)
  const [swipe, setSwipe] = useState(50)
  const [vectorReady, setVectorReady] = useState(false)
  const [showTileIds, setShowTileIds] = useState(false)
  const mapsRef = useRef(new Set<MaplibreMap>())
  const showTileIdsRef = useRef(false)
  showTileIdsRef.current = showTileIds
  const split = mode === 'side-by-side'
  const showQgis = panes.qgis
  const showRustSplit = split && panes.rust
  const showVector = panes.vector
  // Swipe/blend: one raster underlay (prefer QGIS) + vector overlay.
  const swipeBlendRaster: 'qgis' | 'rust' | null = !split
    ? showQgis
      ? 'qgis'
      : panes.rust
        ? 'rust'
        : null
    : null

  const jump = useCallback(
    (id: string) => {
      if (!id) {
        onLocation('')
        return
      }
      const loc = findLocation(id)
      if (!loc) return
      const next: MapParam = {
        zoom: loc.zoom,
        lat: loc.latitude,
        lng: loc.longitude,
      }
      onLocation(id)
      setView(next)
      onMap(next)
    },
    [onLocation, onMap],
  )

  const togglePane = useCallback(
    (id: ComparePaneId) => {
      const next = { ...panes, [id]: !panes[id] }
      if (!next.qgis && !next.rust && !next.vector) return
      onPanes(next)
    },
    [onPanes, panes],
  )

  const onMove = useCallback((e: ViewStateChangeEvent) => {
    setView(clampMapFromEvent(e))
  }, [])

  const onMoveEnd = useCallback(
    (e: ViewStateChangeEvent) => {
      const next = clampMapFromEvent(e)
      setView(next)
      onMap(next)
      const loc = findLocation(locationId)
      if (loc && !isNearCompareLocation(next, loc)) {
        onLocation('')
      }
    },
    [locationId, onLocation, onMap],
  )

  const registerMap = useCallback((map: MaplibreMap) => {
    mapsRef.current.add(map)
    map.showTileBoundaries = showTileIdsRef.current
    map.once('remove', () => {
      mapsRef.current.delete(map)
    })
  }, [])

  const toggleTileIds = useCallback(() => {
    setShowTileIds((prev) => {
      const next = !prev
      for (const m of mapsRef.current) {
        m.showTileBoundaries = next
      }
      return next
    })
  }, [])

  const onRasterLoad = useCallback(
    (e: MapLibreEvent) => {
      installMissingStyleImageResolver(e.target)
      registerMap(e.target)
    },
    [registerMap],
  )

  const onRustLoad = useCallback(
    (e: MapLibreEvent) => {
      installMissingStyleImageResolver(e.target)
      registerMap(e.target)
    },
    [registerMap],
  )

  const onVectorLoad = useCallback(
    (e: MapLibreEvent) => {
      installMissingStyleImageResolver(e.target)
      registerMap(e.target)
      setVectorReady(true)
    },
    [registerMap],
  )

  const shared = useMemo(
    () => ({
      longitude: view.lng,
      latitude: view.lat,
      zoom: view.zoom,
      bearing: 0,
      pitch: 0,
      minZoom: MAP_MIN_ZOOM,
      maxZoom: MAP_MAX_ZOOM,
      mapStyle: baseStyle,
      attributionControl: false as const,
      onMove,
      onMoveEnd,
    }),
    [view.lng, view.lat, view.zoom, onMove, onMoveEnd],
  )

  return (
    <div className="compare">
      <header className="bar">
        <button type="button" className="legend-btn" onClick={onBack}>
          ← Preview
        </button>
        <div
          className="compare-panes-toggles"
          role="group"
          aria-label="Compare panes"
        >
          {COMPARE_PANES.map((p, i) => (
            <span key={p.id} className="compare-panes-item">
              {i > 0 ? (
                <span className="compare-panes-sep" aria-hidden>
                  ·
                </span>
              ) : null}
              <label className="compare-toggle">
                <input
                  type="checkbox"
                  checked={panes[p.id]}
                  onChange={() => togglePane(p.id)}
                />
                {p.label}
              </label>
            </span>
          ))}
        </div>
        <label className="compare-field">
          Location
          <select
            value={location?.id ?? ''}
            onChange={(e) => jump(e.target.value)}
          >
            <option value="">—</option>
            {COMPARE_LOCATIONS.map((l) => (
              <option key={l.id} value={l.id}>
                {l.label}
              </option>
            ))}
          </select>
        </label>
        <label className="compare-field">
          Mode
          <select
            value={mode}
            onChange={(e) => onMode(modeById(e.target.value))}
          >
            {COMPARE_MODES.map((m) => (
              <option key={m.id} value={m.id}>
                {m.label}
              </option>
            ))}
          </select>
        </label>
        <button
          type="button"
          className="legend-btn"
          aria-pressed={showTileIds}
          onClick={toggleTileIds}
          title="MapLibre tile outlines + z/x/y labels"
        >
          {showTileIds ? 'Hide tile IDs' : 'Show tile IDs'}
        </button>
        {mode === 'blend' && showVector && (
          <label className="compare-field compare-field--grow">
            Vector opacity {Math.round(blend * 100)}%
            <input
              type="range"
              min={0}
              max={1}
              step={0.01}
              value={blend}
              onChange={(e) => setBlend(Number(e.target.value))}
            />
          </label>
        )}
        {mode === 'swipe' && showVector && swipeBlendRaster && (
          <label className="compare-field compare-field--grow">
            Swipe {Math.round(swipe)}%
            <input
              type="range"
              min={5}
              max={95}
              step={1}
              value={swipe}
              onChange={(e) => setSwipe(Number(e.target.value))}
            />
          </label>
        )}
      </header>

      <div
        className={
          split
            ? 'compare-panes compare-panes--split'
            : 'compare-panes'
        }
      >
        {/* Side-by-side: each enabled pane in one horizontal row */}
        {split && showQgis && (
          <div className="compare-pane">
            <div className="compare-label">Raster (QGIS)</div>
            <Map
              mapLib={mapLib}
              id="compare-raster"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onRasterLoad}
            >
              <NavigationControl position="top-right" />
              <Source
                id={RASTER_SOURCE}
                type="raster"
                tiles={['/raster/{z}/{x}/{y}.jpg']}
                tileSize={256}
                minzoom={MAP_MIN_ZOOM}
                maxzoom={MAP_MAX_ZOOM}
              />
              <Layer
                id="raster-tiles"
                type="raster"
                source={RASTER_SOURCE}
                paint={{ 'raster-opacity': 1 }}
              />
            </Map>
          </div>
        )}

        {split && showRustSplit && (
          <div className="compare-pane">
            <div className="compare-label">Raster (Rust full-approx)</div>
            <Map
              mapLib={mapLib}
              id="compare-rust"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onRustLoad}
            >
              <Source
                id={RUST_RASTER_SOURCE}
                type="raster"
                tiles={['/raster-rust/{z}/{x}/{y}.webp']}
                tileSize={256}
                minzoom={MAP_MIN_ZOOM}
                maxzoom={MAP_MAX_ZOOM}
              />
              <Layer
                id="rust-raster-tiles"
                type="raster"
                source={RUST_RASTER_SOURCE}
                paint={{ 'raster-opacity': 1 }}
              />
            </Map>
          </div>
        )}

        {split && showVector && (
          <div className="compare-pane">
            <div className="compare-label">Vector</div>
            <Map
              mapLib={mapLib}
              id="compare-vector"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onVectorLoad}
            >
              <Source
                id={SOURCE_ID}
                type="vector"
                url={pmtilesSourceUrl()}
                minzoom={SOURCE_MINZOOM}
                maxzoom={SOURCE_MAXZOOM}
              />
              {vectorReady &&
                vectorLayers.map((layer) => (
                  // eslint-disable-next-line @typescript-eslint/no-explicit-any
                  <Layer key={layer.id} {...(layer as any)} />
                ))}
            </Map>
          </div>
        )}

        {/* Swipe / blend: one raster underlay + vector overlay */}
        {!split && swipeBlendRaster === 'qgis' && (
          <div
            className="compare-pane"
            style={
              mode === 'swipe'
                ? { clipPath: `inset(0 ${100 - swipe}% 0 0)` }
                : undefined
            }
          >
            <div className="compare-label">Raster (QGIS)</div>
            <Map
              mapLib={mapLib}
              id="compare-raster"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onRasterLoad}
            >
              <NavigationControl position="top-right" />
              <Source
                id={RASTER_SOURCE}
                type="raster"
                tiles={['/raster/{z}/{x}/{y}.jpg']}
                tileSize={256}
                minzoom={MAP_MIN_ZOOM}
                maxzoom={MAP_MAX_ZOOM}
              />
              <Layer
                id="raster-tiles"
                type="raster"
                source={RASTER_SOURCE}
                paint={{ 'raster-opacity': 1 }}
              />
            </Map>
          </div>
        )}

        {!split && swipeBlendRaster === 'rust' && (
          <div
            className="compare-pane"
            style={
              mode === 'swipe'
                ? { clipPath: `inset(0 ${100 - swipe}% 0 0)` }
                : undefined
            }
          >
            <div className="compare-label">Raster (Rust full-approx)</div>
            <Map
              mapLib={mapLib}
              id="compare-rust"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onRustLoad}
            >
              <NavigationControl position="top-right" />
              <Source
                id={RUST_RASTER_SOURCE}
                type="raster"
                tiles={['/raster-rust/{z}/{x}/{y}.webp']}
                tileSize={256}
                minzoom={MAP_MIN_ZOOM}
                maxzoom={MAP_MAX_ZOOM}
              />
              <Layer
                id="rust-raster-tiles"
                type="raster"
                source={RUST_RASTER_SOURCE}
                paint={{ 'raster-opacity': 1 }}
              />
            </Map>
          </div>
        )}

        {!split && showVector && (
          <div
            className="compare-pane"
            style={
              mode === 'blend'
                ? {
                    position: 'absolute',
                    inset: 0,
                    opacity: blend,
                    pointerEvents: 'none',
                  }
                : mode === 'swipe'
                  ? {
                      position: 'absolute',
                      inset: 0,
                      clipPath: `inset(0 0 0 ${swipe}%)`,
                      pointerEvents: 'none',
                    }
                  : undefined
            }
          >
            <div className="compare-label">Vector</div>
            <Map
              mapLib={mapLib}
              id="compare-vector"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onVectorLoad}
            >
              <Source
                id={SOURCE_ID}
                type="vector"
                url={pmtilesSourceUrl()}
                minzoom={SOURCE_MINZOOM}
                maxzoom={SOURCE_MAXZOOM}
              />
              {vectorReady &&
                vectorLayers.map((layer) => (
                  // eslint-disable-next-line @typescript-eslint/no-explicit-any
                  <Layer key={layer.id} {...(layer as any)} />
                ))}
            </Map>
          </div>
        )}
      </div>
    </div>
  )
}
