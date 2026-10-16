import { legendGroups, type LegendEntry } from '../style/legend'

type Props = {
  entries?: LegendEntry[]
  zoom: number
  hidden: ReadonlySet<string>
  onToggle: (layerId: string) => void
  onShowAll: () => void
  onHideAll: () => void
}

function Swatch({ entry }: { entry: LegendEntry }) {
  if (entry.kind === 'line') {
    return (
      <span
        className="legend-swatch legend-swatch--line"
        style={{ background: entry.color }}
        aria-hidden
      />
    )
  }
  if (entry.kind === 'circle') {
    return (
      <span
        className="legend-swatch legend-swatch--circle"
        style={{ background: entry.color }}
        aria-hidden
      />
    )
  }
  return (
    <span
      className="legend-swatch legend-swatch--fill"
      style={{ background: entry.color }}
      aria-hidden
    />
  )
}

export function Legend({
  entries,
  zoom,
  hidden,
  onToggle,
  onShowAll,
  onHideAll,
}: Props) {
  const groups = legendGroups(entries)

  return (
    <aside className="legend" aria-label="Layer legend">
      <div className="legend-head">
        <h1 className="legend-title">Straßenraumkarte</h1>
        <p className="legend-sub">vector preview · z{zoom.toFixed(1)}</p>
        <div className="legend-actions">
          <button type="button" className="legend-btn" onClick={onShowAll}>
            Show all
          </button>
          <button type="button" className="legend-btn" onClick={onHideAll}>
            Hide all
          </button>
        </div>
      </div>

      <div className="legend-body">
        {groups.map((group) => (
          <section key={group.id} className="legend-group">
            <h2 className="legend-group-title">{group.label}</h2>
            <ul className="legend-list">
              {group.entries.map((entry) => {
                const belowMin = zoom < entry.minzoom
                const checked = !hidden.has(entry.id)
                return (
                  <li key={entry.id}>
                    <label
                      className={
                        belowMin ? 'legend-row legend-row--dim' : 'legend-row'
                      }
                      title={
                        belowMin
                          ? `Visible from z${entry.minzoom}`
                          : `z${entry.minzoom}–${entry.maxzoom}`
                      }
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => onToggle(entry.id)}
                      />
                      <Swatch entry={entry} />
                      <span className="legend-label">{entry.label}</span>
                      <span className="legend-zoom">z{entry.minzoom}+</span>
                    </label>
                  </li>
                )
              })}
            </ul>
          </section>
        ))}
      </div>
    </aside>
  )
}
