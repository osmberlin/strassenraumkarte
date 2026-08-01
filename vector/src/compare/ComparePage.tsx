import { useCallback, useMemo, useState } from 'react'
import type { MapLibreEvent } from 'maplibre-gl'
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
  locationById,
  modeById,
  type CompareLocation,
  type CompareMode,
  type ComparePaneId,
  type ComparePanes,
} from '../../locations'
import { installMissingStyleImageResolver } from '../lib/missing-style-images'
import { pmtilesSourceUrl } from '../maplibre-setup'
import { emptyBaseStyle } from '../style/build-style'
import { SOURCE_ID, absoluteSpriteUrl } from '../style/source'
import { qgisLayerSpecs } from '../style/qgis'

const RASTER_SOURCE = 'qgis-raster'
const RUST_RASTER_SOURCE = 'rust-raster'
const vectorLayers = qgisLayerSpecs() as LayerSpecification[]
const baseStyle = emptyBaseStyle({
  name: 'compare',
  sprite: absoluteSpriteUrl(window.location.origin),
})

type View = {
  longitude: number
  latitude: number
  zoom: number
  bearing: number
  pitch: number
}

function viewFromLocation(loc: CompareLocation): View {
  return {
    longitude: loc.longitude,
    latitude: loc.latitude,
    zoom: loc.zoom,
    bearing: 0,
    pitch: 0,
  }
}

type Props = {
  locationId: string
  mode: CompareMode
  panes: ComparePanes
  onLocation: (id: string) => void
  onMode: (mode: CompareMode) => void
  onPanes: (panes: ComparePanes) => void
  onBack: () => void
}

export function ComparePage({
  locationId,
  mode,
  panes,
  onLocation,
  onMode,
  onPanes,
  onBack,
}: Props) {
  const location = locationById(locationId)
  const [view, setView] = useState<View>(() => viewFromLocation(location))
  const [blend, setBlend] = useState(0.5)
  const [swipe, setSwipe] = useState(50)
  const [vectorReady, setVectorReady] = useState(false)
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
      const loc = locationById(id)
      onLocation(id)
      setView(viewFromLocation(loc))
    },
    [onLocation],
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
    const vs = e.viewState
    setView({
      longitude: vs.longitude,
      latitude: vs.latitude,
      zoom: Math.min(MAP_MAX_ZOOM, Math.max(MAP_MIN_ZOOM, vs.zoom)),
      bearing: vs.bearing,
      pitch: vs.pitch,
    })
  }, [])

  const onRasterLoad = useCallback((e: MapLibreEvent) => {
    installMissingStyleImageResolver(e.target)
  }, [])

  const onRustLoad = useCallback((e: MapLibreEvent) => {
    installMissingStyleImageResolver(e.target)
  }, [])

  const onVectorLoad = useCallback((e: MapLibreEvent) => {
    installMissingStyleImageResolver(e.target)
    setVectorReady(true)
  }, [])

  const shared = useMemo(
    () => ({
      ...view,
      minZoom: MAP_MIN_ZOOM,
      maxZoom: MAP_MAX_ZOOM,
      mapStyle: baseStyle,
      attributionControl: false as const,
      onMove,
    }),
    [view, onMove],
  )

  const title = COMPARE_PANES.filter((p) => panes[p.id])
    .map((p) => p.label)
    .join(' · ')

  return (
    <div className="compare">
      <header className="bar">
        <button type="button" className="legend-btn" onClick={onBack}>
          ← Preview
        </button>
        <strong>{title || 'Compare'}</strong>
        <label className="compare-field">
          Location
          <select value={location.id} onChange={(e) => jump(e.target.value)}>
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
        <div className="compare-field compare-panes-toggles" role="group" aria-label="Panes">
          {COMPARE_PANES.map((p) => (
            <label key={p.id} className="compare-toggle">
              <input
                type="checkbox"
                checked={panes[p.id]}
                onChange={() => togglePane(p.id)}
              />
              {p.label}
            </label>
          ))}
        </div>
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
        <span className="muted">
          {location.note}
          {panes.rust ? ' · Rust = highway_area isolate (starter bbox)' : ''}
        </span>
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
            <div className="compare-label">Raster (Rust)</div>
            <Map
              id="compare-rust"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onRustLoad}
            >
              <Source
                id={RUST_RASTER_SOURCE}
                type="raster"
                tiles={['/raster-rust/{z}/{x}/{y}.png']}
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
            <div className="compare-label">Raster (Rust)</div>
            <Map
              id="compare-rust"
              style={{ width: '100%', height: '100%' }}
              {...shared}
              onLoad={onRustLoad}
            >
              <NavigationControl position="top-right" />
              <Source
                id={RUST_RASTER_SOURCE}
                type="raster"
                tiles={['/raster-rust/{z}/{x}/{y}.png']}
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
