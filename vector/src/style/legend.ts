/**
 * Legend entries for the preview sidebar — grows with QGIS-faithful categories.
 */
import {
  BUILDING_PARTS_FILL,
  BUILDING_SHADE_FILL,
  HIGHWAY_AREA_DEFAULT,
  LANDUSE_FILL,
  MARKING_DEFAULT,
  PATH_CYCLEWAY,
  PATH_FOOTWAY,
  PATH_SIDEWALK,
  SERVICE_LINE,
  TACTILE,
  PITCH_FILL_DEFAULT,
  SANDPIT_FILL,
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
      id: 'pitch',
      label: 'pitch',
      group: 'ground',
      kind: 'fill',
      color: PITCH_FILL_DEFAULT,
      minzoom: 15,
      maxzoom: 16,
      layerIds: ['pitch-fill', 'pitch-surface', 'pitch-markings'],
    },
    {
      id: 'sandpit',
      label: 'sandpit',
      group: 'ground',
      kind: 'fill',
      color: SANDPIT_FILL,
      minzoom: 15,
      maxzoom: 16,
      layerIds: ['sandpit-'],
    },
    {
      id: 'water',
      label: 'water',
      group: 'ground',
      kind: 'fill',
      color: WATER_FILL,
      minzoom: 15,
      maxzoom: 16,
      layerIds: ['water-fill', 'water-shore', 'water-inner'],
    },
    {
      id: 'wetland',
      label: 'wetland',
      group: 'ground',
      kind: 'fill',
      color: '#9bb88a',
      minzoom: 15,
      maxzoom: 16,
      layerIds: ['wetland-'],
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
      id: 'landscape',
      label: 'landscape (cliff / rock)',
      group: 'ground',
      kind: 'line',
      color: '#965220',
      minzoom: 15,
      maxzoom: 16,
      layerIds: ['landscape_way-', 'landscape_node-'],
    },
    {
      id: 'bridge',
      label: 'bridge',
      group: 'streets',
      kind: 'fill',
      color: '#dddddd',
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['bridge_shade-', 'bridge-fill'],
    },
    {
      id: 'railway',
      label: 'railway',
      group: 'streets',
      kind: 'line',
      color: '#808080',
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['railway_way-', 'railway_node-'],
    },
    {
      id: 'highway-area',
      label: 'highway area',
      group: 'streets',
      kind: 'fill',
      color: HIGHWAY_AREA_DEFAULT,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['highway_area-fill', 'highway_area-blur', 'highway_area-pattern'],
    },
    {
      id: 'highway-path',
      label: 'path / footway',
      group: 'streets',
      kind: 'line',
      color: PATH_FOOTWAY,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['highway_path-fill', 'highway_path-casing'],
    },
    {
      id: 'highway-path-sidewalk',
      label: 'sidewalk / sidepath',
      group: 'streets',
      kind: 'line',
      color: PATH_SIDEWALK,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['highway_path-fill-sidewalk', 'highway_path-fill-sidepath'],
    },
    {
      id: 'highway-path-cycleway',
      label: 'cycleway (line)',
      group: 'streets',
      kind: 'line',
      color: PATH_CYCLEWAY,
      minzoom: 15,
      maxzoom: 17,
      layerIds: ['highway_path-fill-cycleway'],
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
      id: 'tactile',
      label: 'tactile paving',
      group: 'streets',
      kind: 'line',
      color: TACTILE,
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['tactile_paving-line'],
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
      id: 'housenumber',
      label: 'housenumber',
      group: 'labels',
      kind: 'circle',
      color: '#b7b7b7',
      minzoom: 18,
      maxzoom: 20,
      layerIds: ['label-housenumber'],
    },
    {
      id: 'markings-poly',
      label: 'road marking (area)',
      group: 'detail',
      kind: 'fill',
      color: MARKING_DEFAULT,
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['road_marking_polygon-'],
    },
    {
      id: 'markings-way',
      label: 'road marking (line)',
      group: 'detail',
      kind: 'line',
      color: MARKING_DEFAULT,
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['road_marking_way-'],
    },
    {
      id: 'markings-node',
      label: 'road marking (arrow / sign)',
      group: 'detail',
      kind: 'circle',
      color: MARKING_DEFAULT,
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['road_marking_node-'],
    },
    {
      id: 'separation',
      label: 'separation (bollard / bump)',
      group: 'detail',
      kind: 'circle',
      color: '#505050',
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['separation-'],
    },
    {
      id: 'furniture',
      label: 'street furniture',
      group: 'detail',
      kind: 'circle',
      color: '#63d9c6',
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['feature_node-', 'feature_way-', 'feature_polygon-'],
    },
    {
      id: 'barriers',
      label: 'barriers',
      group: 'detail',
      kind: 'line',
      color: '#505050',
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['barrier_node-', 'barrier_way-', 'barrier_polygon-'],
    },
    {
      id: 'playground',
      label: 'playground equipment',
      group: 'detail',
      kind: 'fill',
      color: '#d2c8a0',
      minzoom: 17,
      maxzoom: 18,
      layerIds: ['playground_node-', 'playground_way-', 'playground_polygon-'],
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
      label: 'street / waterway labels',
      group: 'labels',
      kind: 'line',
      color: '#dddddd',
      minzoom: 15,
      maxzoom: 19,
      layerIds: ['label-highway', 'label-waterway', 'label-landuse', 'label-water-body'],
    },
    {
      id: 'places',
      label: 'place names',
      group: 'labels',
      kind: 'circle',
      color: '#d7d8c5',
      minzoom: 15,
      maxzoom: 19,
      layerIds: ['place_node-', 'place_polygon-'],
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
