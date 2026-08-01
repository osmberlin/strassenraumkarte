/**
 * Legend entries for the preview sidebar — grows with QGIS-faithful categories.
 */
import {
  BUILDING_PARTS_FILL,
  BUILDING_SHADE_FILL,
  HIGHWAY_AREA_DEFAULT,
  LANDUSE_FILL,
  MARKING_DEFAULT,
  SERVICE_LINE,
  TREE_CROWN,
  WATER_FILL,
  WATERWAY_LINE,
} from './colors'

export type LegendKind = 'fill' | 'line' | 'circle'

export type LegendEntry = {
  id: string
  label: string
  group: string
  kind: LegendKind
  color: string
  minzoom: number
  maxzoom: number
  /** Style layer id prefixes to toggle (matched with startsWith / exact). */
  layerIds: string[]
}

export type LegendGroup = {
  id: string
  label: string
  entries: LegendEntry[]
}

const GROUP_ORDER = [
  { id: 'ground', label: 'Ground' },
  { id: 'streets', label: 'Streets' },
  { id: 'buildings', label: 'Buildings' },
  { id: 'detail', label: 'Detail' },
  { id: 'labels', label: 'Labels' },
] as const

/** Representative landuse colours (one swatch per unique fill). */
function landuseLegendEntries(): LegendEntry[] {
  const byColor = new Map<string, string[]>()
  for (const [cls, color] of Object.entries(LANDUSE_FILL)) {
    if (color === '#0000ff') continue // QGIS debug placeholder
    const list = byColor.get(color) ?? []
    list.push(cls)
    byColor.set(color, list)
  }
  return [...byColor.entries()].map(([color, classes]) => ({
    id: `landuse-${color}`,
    label: classes.slice(0, 3).join(', ') + (classes.length > 3 ? '…' : ''),
    group: 'ground',
    kind: 'fill' as const,
    color,
    minzoom: 15,
    maxzoom: 16,
    layerIds: ['landuse-fill', 'landuse-forest'],
  }))
}

export function legendEntries(): LegendEntry[] {
  return [
    ...landuseLegendEntries(),
    {
      id: 'water',
      label: 'water',
      group: 'ground',
      kind: 'fill',
      color: WATER_FILL,
      minzoom: 15,
      maxzoom: 16,
      layerIds: ['water-fill', 'water-inner'],
    },
    {
      id: 'waterway',
      label: 'waterway',
      group: 'ground',
      kind: 'line',
      color: WATERWAY_LINE,
      minzoom: 15,
      maxzoom: 16,
      layerIds: ['waterway-line', 'waterway-tunnel'],
    },
    {
      id: 'highway-area',
      label: 'highway area',
      group: 'streets',
      kind: 'fill',
      color: HIGHWAY_AREA_DEFAULT,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['highway_area-fill', 'highway_area-blur'],
    },
    {
      id: 'highway-service',
      label: 'service',
      group: 'streets',
      kind: 'line',
      color: SERVICE_LINE,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['highway_service-line'],
    },
    {
      id: 'building-shade',
      label: 'building shade',
      group: 'buildings',
      kind: 'fill',
      color: BUILDING_SHADE_FILL,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['building-shade'],
    },
    {
      id: 'building',
      label: 'building',
      group: 'buildings',
      kind: 'fill',
      color: BUILDING_PARTS_FILL,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['building-parts', 'building-fill', 'building-lines'],
    },
    {
      id: 'markings',
      label: 'road markings',
      group: 'detail',
      kind: 'fill',
      color: MARKING_DEFAULT,
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['road_marking_'],
    },
    {
      id: 'tree',
      label: 'tree crown',
      group: 'detail',
      kind: 'circle',
      color: TREE_CROWN,
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['tree-'],
    },
    {
      id: 'labels',
      label: 'labels',
      group: 'labels',
      kind: 'line',
      color: '#dddddd',
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['label-'],
    },
  ]
}

export function legendGroups(entries: LegendEntry[] = legendEntries()): LegendGroup[] {
  return GROUP_ORDER.map((g) => ({
    id: g.id,
    label: g.label,
    entries: entries.filter((e) => e.group === g.id),
  })).filter((g) => g.entries.length > 0)
}

/** Whether a MapLibre layer id belongs to a legend entry. */
export function layerMatchesLegend(layerId: string, entry: LegendEntry): boolean {
  return entry.layerIds.some(
    (prefix) => layerId === prefix || layerId.startsWith(prefix),
  )
}

/** @deprecated — kept for prep-color imports */
export const PREP_COLORS = {
  fill: '#2f6fed',
  fillOutline: '#1d4ed8',
  line: '#7c3aed',
  circle: '#dc2626',
  background: '#ededed',
} as const
