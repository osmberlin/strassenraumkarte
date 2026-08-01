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
  locationById,
  modeById,
  type CompareLocation,
  type CompareMode,
} from '../../locations'
import { installMissingStyleImageResolver } from '../lib/missing-style-images'
import { pmtilesSourceUrl } from '../maplibre-setup'
import { emptyBaseStyle } from '../style/build-style'
import { SOURCE_ID } from '../style/source'
import { qgisLayerSpecs } from '../style/qgis'

const RASTER_SOURCE = 'qgis-raster'
const vectorLayers = qgisLayerSpecs() as LayerSpecification[]
const baseStyle = emptyBaseStyle({ name: 'compare' })

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
  onLocation: (id: string) => void
  onMode: (mode: CompareMode) => void
  onBack: () => void
}

export function ComparePage({ locationId, mode, onLocation, onMode, onBack }: Props) {
  const location = locationById(locationId)
  const [view, setView] = useState<View>(() => viewFromLocation(location))
  const [blend, setBlend] = useState(0.5)
  const [swipe, setSwipe] = useState(50)

  const jump = useCallback(
    (id: string) => {
      const loc = locationById(id)
      onLocation(id)
      setView(viewFromLocation(loc))
    },
    [onLocation],
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

  const onVectorLoad = useCallback((e: MapLibreEvent) => {
    installMissingStyleImageResolver(e.target)
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

  return (
    <div className="compare">
      <header className="bar">
        <button type="button" className="legend-btn" onClick={onBack}>
          ← Preview
        </button>
        <strong>Raster vs vector</strong>
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
        {mode === 'blend' && (
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
        {mode === 'swipe' && (
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
        <span className="muted">{location.note}</span>
      </header>

      <div
        className={
          mode === 'side-by-side' ? 'compare-panes compare-panes--split' : 'compare-panes'
        }
      >
        {(mode === 'side-by-side' || mode === 'blend' || mode === 'swipe') && (
          <div
            className="compare-pane"
            style={
              mode === 'swipe'
                ? { clipPath: `inset(0 ${100 - swipe}% 0 0)` }
                : mode === 'blend'
                  ? { opacity: 1 }
                  : undefined
            }
          >
            <div className="compare-label">Raster (QGIS)</div>
            <Map id="compare-raster" style={{ width: '100%', height: '100%' }} {...shared}>
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

        <div
          className="compare-pane"
          style={
            mode === 'side-by-side'
              ? undefined
              : mode === 'blend'
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
            {vectorLayers.map((layer) => (
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              <Layer key={layer.id} {...(layer as any)} />
            ))}
          </Map>
        </div>
      </div>
    </div>
  )
}
