/**
 * Legend entries for the preview sidebar.
 *
 * Derived from the active style paints so the panel grows as we add QGIS-
 * faithful categories (w4c+). Keep colours in sync with `basic.ts` until
 * category-level paints land.
 */
import { LAYERS, type GeomKind, type LayerDef } from '../../layers'
import { CORE_PAINT_ORDER } from './order'

export const PREP_COLORS = {
  fill: '#2f6fed',
  fillOutline: '#1d4ed8',
  line: '#7c3aed',
  circle: '#dc2626',
  background: '#ededed',
} as const

export type LegendEntry = {
  /** Matches MapLibre style layer id (`${sourceLayer}-fill` etc.). */
  id: string
  sourceLayer: string
  label: string
  group: LayerDef['group']
  kind: GeomKind
  /** Swatch fill / stroke colour. */
  color: string
  minzoom: number
  maxzoom: number
}

const GROUP_LABELS: Record<LayerDef['group'], string> = {
  ground: 'Ground',
  streets: 'Streets',
  buildings: 'Buildings',
  detail: 'Detail',
  labels: 'Labels',
}

function paintOrderIndex(id: string): number {
  const idx = (CORE_PAINT_ORDER as readonly string[]).indexOf(id)
  return idx === -1 ? CORE_PAINT_ORDER.length + LAYERS.findIndex((l) => l.id === id) : idx
}

function colorFor(kind: GeomKind): string {
  if (kind === 'fill') return PREP_COLORS.fill
  if (kind === 'line') return PREP_COLORS.line
  return PREP_COLORS.circle
}

function labelFor(def: LayerDef): string {
  return def.id.replaceAll('_', ' ')
}

/** Flat list in paint order — grows when LAYERS / style categories expand. */
export function legendEntries(): LegendEntry[] {
  return [...LAYERS]
    .sort((a, b) => paintOrderIndex(a.id) - paintOrderIndex(b.id))
    .map((def) => ({
      id: `${def.id}-${def.paint}`,
      sourceLayer: def.id,
      label: labelFor(def),
      group: def.group,
      kind: def.paint,
      color: colorFor(def.paint),
      minzoom: def.minzoom,
      maxzoom: def.maxzoom,
    }))
}

export type LegendGroup = {
  id: LayerDef['group']
  label: string
  entries: LegendEntry[]
}

export function legendGroups(entries: LegendEntry[] = legendEntries()): LegendGroup[] {
  const order: LayerDef['group'][] = ['ground', 'streets', 'buildings', 'detail', 'labels']
  return order
    .map((id) => ({
      id,
      label: GROUP_LABELS[id],
      entries: entries.filter((e) => e.group === id),
    }))
    .filter((g) => g.entries.length > 0)
}
