/**
 * Named comparison viewpoints over the Neukölln starter bbox.
 * Chosen via density queries (trees / buildings / parking) + water + intersection.
 */
export type CompareLocation = {
  id: string
  label: string
  longitude: number
  latitude: number
  zoom: number
  note: string
}

export const COMPARE_LOCATIONS: CompareLocation[] = [
  {
    id: 'intersection',
    label: 'Intersection',
    longitude: 13.4235,
    latitude: 52.4771,
    zoom: 18,
    note: 'Herrfurthstraße — red cycle lane + nearby playground',
  },
  {
    id: 'dense-trees',
    label: 'Dense trees',
    longitude: 13.42598,
    latitude: 52.46216,
    zoom: 18,
    note: 'Highest tree count in a 0.002° cell',
  },
  {
    id: 'dense-housing',
    label: 'Dense housing',
    longitude: 13.43528,
    latitude: 52.46679,
    zoom: 17,
    note: 'Highest building count in a 0.002° cell',
  },
  {
    id: 'parking-street',
    label: 'Parking street',
    longitude: 13.43338,
    latitude: 52.4692,
    zoom: 18,
    note: 'Dense parking / parking_space areas',
  },
  {
    id: 'park-water',
    label: 'Park / water edge',
    longitude: 13.46847,
    latitude: 52.44942,
    zoom: 16,
    note: 'Largest dissolved water body centroid',
  },
]

export type CompareMode = 'side-by-side' | 'swipe' | 'blend'

export const COMPARE_MODES: { id: CompareMode; label: string }[] = [
  { id: 'side-by-side', label: 'Side by side' },
  { id: 'swipe', label: 'Swipe' },
  { id: 'blend', label: 'Blend' },
]

export function locationById(id: string | null | undefined): CompareLocation {
  return COMPARE_LOCATIONS.find((l) => l.id === id) ?? COMPARE_LOCATIONS[0]!
}

export function modeById(id: string | null | undefined): CompareMode {
  if (id === 'swipe' || id === 'blend' || id === 'side-by-side') return id
  return 'side-by-side'
}

/** Compare panes that can be toggled on/off. */
export type ComparePaneId = 'qgis' | 'rust' | 'vector'

export const COMPARE_PANES: { id: ComparePaneId; label: string }[] = [
  { id: 'qgis', label: 'QGIS' },
  { id: 'rust', label: 'Rust' },
  { id: 'vector', label: 'Vector' },
]

export type ComparePanes = Record<ComparePaneId, boolean>

export const DEFAULT_COMPARE_PANES: ComparePanes = {
  qgis: true,
  rust: true,
  vector: true,
}

/** Parse `?panes=qgis,rust,vector` (comma-separated). Empty/invalid → all on. */
export function panesFromParam(raw: string | null | undefined): ComparePanes {
  if (raw == null || raw.trim() === '') return { ...DEFAULT_COMPARE_PANES }
  const set = new Set(
    raw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
  )
  if (set.size === 0) return { ...DEFAULT_COMPARE_PANES }
  const next: ComparePanes = { qgis: false, rust: false, vector: false }
  for (const id of COMPARE_PANES) {
    if (set.has(id.id)) next[id.id] = true
  }
  // Keep at least one pane visible.
  if (!next.qgis && !next.rust && !next.vector) return { ...DEFAULT_COMPARE_PANES }
  return next
}

export function panesToParam(panes: ComparePanes): string {
  return COMPARE_PANES.filter((p) => panes[p.id])
    .map((p) => p.id)
    .join(',')
}
