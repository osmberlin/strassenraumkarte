# 01 · Catalyst look for the viewers

Header and control restyle of the four viewers, with the design viewer's look as the reference. Behaviour is unchanged; the screenshots show the same states before and after.

Context and decisions: [docs/VIEWERS.md](../../VIEWERS.md).

## What to look at

| Viewer | Before | After | Look for |
| --- | --- | --- | --- |
| Vector app, main preview | [before](before-vector-main.jpg) | [after](after-vector-main.jpg) | Light header (white/90, hairline), "Compare QGIS · Rust · Vector" as outline button, status text in green |
| Vector app, compare | [before](before-vector-compare.jpg) | [after](after-vector-compare.jpg) | Mode is a segmented control (Side by side · Swipe · Blend), Location is a chevron select, pane labels are badges. The Rust pane is empty at this preset: `latest-rust` does not cover it (see VIEWERS.md) |
| QGIS run preview | [before](before-qgis-preview.jpg) | [after](after-qgis-preview.jpg) | Zoom card, `run.sh` form with uppercase labels, outline buttons, primary "run.sh starten" in zinc-900, selects with chevrons |
| Design viewer | [before](before-design-viewer.jpg) | [after](after-design-viewer.jpg) | Reference look (unchanged), plus the **Vektor-Vergleich ↗** button, which opens the vector compare on the same view |

## Checks

- Console: vector main and QGIS preview have no errors. The vector compare logs 404s for Rust tiles that are not in `latest-rust` at this preset (expected). The design viewer logs one failed `/tailwindcss` request from the Tailwind browser build; the page is styled (see VIEWERS.md).
- Mode switching in the vector compare: Swipe checked in the built-in browser, the URL follows (`mode=swipe`) and the swipe slider appears.
- Viewer link: `#map=17/52.47600/13.42000` in the design viewer gives `…/?compare=1&panes=qgis,rust,vector&map=17/52.47600/13.42000` on the vector side.

## Reproduce

Start the four viewers as in [VIEWERS.md](../../VIEWERS.md) (vector `bun run dev`, `render/preview_server.py`, `serve_viewer.sh`), then:

```bash
cd vector
STEP=after bun run capture-viewers   # STEP=before for the state before a change
```

`VIEWER_URL=http://127.0.0.1:<port>/` points the design viewer at another port. The script prints console and page errors per viewer and writes `docs/viewers/01-catalyst-look/<STEP>-<viewer>.jpg`.
