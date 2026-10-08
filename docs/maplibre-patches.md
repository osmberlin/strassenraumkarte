# Local MapLibre patches

We test our own renderer features by patching the installed `maplibre-gl` with
[`bun patch`](https://bun.sh/docs/install/patch). The patches live in `vector/patches/` and are
applied on every `bun install` (`patchedDependencies` in `vector/package.json`).

Why patch instead of fork: the edits are small, reviewable as a diff next to the style that
uses them, and need no separate build. If a patch grows past a few hundred lines, or we want to
propose it upstream, move it to a fork and write it against the TypeScript sources.

## How it is wired

- `maplibre-gl` ships unminified `dist/*-dev.mjs` bundles. The patch points the package's
  `exports` at `maplibre-gl-dev.mjs`, so every import gets the patched, readable build.
  `src/maplibre-setup.ts` loads the matching `maplibre-gl-worker-dev.mjs`.
- `src/maplibre-setup.ts` exports `mapLib`; every react-map-gl `<Map>` must receive
  `mapLib={mapLib}`. Otherwise react-map-gl lazily imports a second copy of MapLibre that never
  saw `addProtocol('pmtiles')`.
- New style properties also have to exist in `@maplibre/maplibre-gl-style-spec` (types and the
  reference JSON in both `index.mjs` and `index.cjs` — Bun loads the CJS build), or
  `bun run validate-style` and `tsc` reject them. That is the second patch file.
- The minified production bundles are **not** patched. A production build therefore ships the
  larger dev bundle until a patch is upstreamed or moved to a fork build.

## Changing a patch

```bash
cd vector
bun patch maplibre-gl@6.0.0          # makes node_modules/maplibre-gl editable
# edit node_modules/maplibre-gl/dist/maplibre-gl-dev.mjs (renderer)
#      node_modules/maplibre-gl/dist/maplibre-gl-shared-dev.mjs (spec JSON, paint properties, worker code)
#      node_modules/maplibre-gl/dist/maplibre-gl.d.ts (types)
bun patch --commit node_modules/maplibre-gl
rm -rf node_modules/.vite            # Vite caches the pre-bundled dependency
bun run dev
```

The bundles keep `//#region src/…` markers, so the upstream source file of any function is easy
to find (`node_modules/maplibre-gl/src` has the TypeScript for reference).

When bumping `maplibre-gl`, the patch has to be re-applied by hand against the new version.

## Pitfalls we hit (read before debugging a blank map)

- **Blank vector map, console says `URL scheme "pmtiles" is not supported`.** Two copies of
  MapLibre are loaded: ours (where `addProtocol` ran) and one that react-map-gl imported
  lazily. Vite pre-bundles them separately. Fix: `mapLib={mapLib}` on every `<Map>`. A request
  for `…/.vite/deps/maplibre-gl-worker.mjs` in the network tab is the same symptom (the second
  copy never got `setWorkerUrl`).
- **Do not alias `maplibre-gl` in `vite.config.ts`** to reach the dev bundle. It produced the
  duplicate above in a harder-to-see form. Redirecting `exports` inside the patch is what works.
- **`validate-style` says `unknown property`** although the spec patch is applied: Bun resolves
  `@maplibre/maplibre-gl-style-spec` to `dist/index.cjs`, Vite to `dist/index.mjs`. Patch both.
- **A patch edit has no effect in the browser:** `rm -rf node_modules/.vite` and restart
  `bun run dev`. Vite does not notice changes inside `node_modules`.
- **Check the console first.** `bun run e2e` fails on any console error at the compare
  locations; a thrown error in the style builder looks the same as a broken renderer (grey map).
- **Judge by looking, not by the diff score.** The pixelmatch percentage from
  `bun run screenshots` is dominated by labels, shadows and texture noise; a real improvement
  can move it by 0.1 %. Use the montages in `docs/maplibre-progress/`.
- **Compare locations must lie inside the tile extent** (`bun run scripts/inspect-pmtiles.ts`
  prints the bounds). Outside it both panes are blank and the diff looks perfect.
- **QGIS scale → MapLibre zoom is `log2(591657528 / scale) − 1`.** QGIS tiles are 256 px,
  MapLibre zooms count 512 px tiles. Use `scaleToZoom()` from `src/style/metres.ts`; without the
  −1 every scale-gated layer shows up one zoom level late.
- **Read the QGIS project before trusting the port.** Several "MapLibre can't do this"
  differences were port mistakes: a building footprint layer QGIS does not have, dash arrays
  scaled by line width, an inverted shadow angle, swimming pools styled as plain landuse. The
  unzipped `.qgs` XML answers these in minutes.
- **`*-layer-*` properties cost a full-screen pass per layer.** Merge features into one layer
  with `match` expressions instead of one layer per class.

## Patches

### `{fill,line}-layer-blend` — layer compositing modes

Closes gap #2 in [maplibre-style-gaps.md](./maplibre-style-gaps.md). Property names follow the
upstream proposal ([style-spec#1661](https://github.com/maplibre/maplibre-style-spec/issues/1661),
draft implementation [gl-js PR #8073](https://github.com/maplibre/maplibre-gl-js/pull/8073)), so
the style keeps working when that lands and this patch can be dropped.

```ts
paint: { 'fill-pattern': 'surface/sett', 'fill-opacity': 0.12, 'fill-layer-blend': 'multiply' }
```

Values: `normal` (default), `multiply`, `screen`, `plus`.

How it works: MapLibre 6 already renders a layer into a scratch framebuffer when
`*-layer-opacity < 1`. The patch takes the same path when a blend mode is set and composites the
framebuffer with a different GL blend function (source is premultiplied):

| Mode | `blendFunc` | Result |
|---|---|---|
| multiply | `DST_COLOR, ONE_MINUS_SRC_ALPHA` | `S·D + D·(1 − Sₐ)` |
| screen | `ONE, ONE_MINUS_SRC_COLOR` | `S + D·(1 − S)` |
| plus | `ONE, ONE` | `S + D` |

Because the whole layer is composited at once, features inside one layer do not multiply with
each other — the same semantics as a QGIS *layer* blend mode.

Limits: only modes expressible with fixed-function blending (the upstream proposal also has
`overlay`, `color`, `luminosity`, `erase`, which need a backdrop texture). Each blended layer
costs one full-screen composite, so put all features that share a mode into one layer
(`surfacePatternLayer` in `src/style/expr.ts` does this for the surface textures).

### `{fill,line}-layer-blur` — Gaussian blur of a whole layer

Closes gap #1 (drop shadows) in [maplibre-style-gaps.md](./maplibre-style-gaps.md); there is no
upstream proposal for 2D layers.

```ts
paint: {
  'fill-color': '#000',
  'fill-opacity': 0.138,                 // per feature: overlapping shadows darken each other
  'fill-translate': […], 'fill-translate-anchor': 'map',
  'fill-layer-blur': ['interpolate', ['exponential', 2], ['zoom'], 15, 0.67, 20, 21.4],
  'fill-layer-blend': 'multiply',
}
```

Value: blur radius in CSS pixels, zoom expressions allowed. It is the QGIS `blur_level`
converted to pixels; internally σ = radius / 2 and the kernel is cut at 3σ. Use
`layerShadow()` from `src/style/effects.ts` instead of writing this by hand — it also converts
QGIS MapUnits and the offset angle.

How it works: the layer is rendered to the scratch framebuffer, blurred horizontally into a
second framebuffer (`painter.layerBlurFbo`), then blurred vertically while being composited
with the layer opacity and blend mode. 33 taps per pass with linear filtering.

Things to know:

- **QGIS effect sizes in MapUnits are Web-Mercator metres**, not ground metres — unlike symbol
  sizes they are not multiplied by `@mercator_scale`. `layerShadow` converts at the equator.
- **QGIS effect angles are clockwise from north** (135 = lower right).
- **Per-feature vs per-layer:** a QGIS effect on a *symbol layer* is applied per feature, one on
  the *renderer* per layer. Put the opacity in `fill-opacity` for the first and in
  `fill-layer-opacity` for the second. Per-feature opacity inside the framebuffer followed by a
  multiply composite gives exactly the stacked-multiply result `D·(1 − a)ⁿ`.
- **Also check the symbol alpha.** The effect opacity is scaled by it (building parts: 0.4 × 0.7).
- **A shadow cannot fall on features of its own layer.** QGIS interleaves shadow and source per
  feature; here the whole shadow layer sits below the whole source layer.
- The blur reads only what is on screen, so a shadow of something just outside the viewport is
  approximated by edge clamping.
- Cost: two extra full-screen passes per blurred layer.

#### `{fill,line}-layer-blur-mode` — inner shadows and edge fades

Combines the blurred layer alpha `b` with the unblurred layer `S` in the final pass:

| Mode | Output | Use |
|---|---|---|
| `normal` | blurred layer | drop shadow, outer glow |
| `inner-edge` | `S·(1 − b)` | QGIS innerShadow / innerGlow: strongest at the polygon edge, gone one radius inside, nothing outside |
| `inner-core` | `S·(2b − 1)` | zero at the edge, full one radius inside — a cheap stand-in for a Shapeburst fade |

`innerShadow()` and `highwayInnerBlur()` in `src/style/effects.ts` use `inner-edge`. Before the
patch these were offset blurred lines, which peaked *inside* the polygon and read as a hard
kerb line along every carriageway.

`patches/tools/apply-layer-blur.py` and `apply-layer-blur-mode.py` are the scripts that made the edits; the first documents every
anchor and both are the starting point when re-applying to a new MapLibre version.

### `symbol-layer-opacity` — opacity of a flattened symbol layer

MapLibre 6 has `fill-layer-opacity` and `line-layer-opacity` but nothing for symbols.

```ts
paint: { 'symbol-layer-opacity': 0.25 }   // tree crowns
```

Icons and text of the layer are drawn at their own opacity into the scratch framebuffer, which
is then composited once. Overlapping symbols do not add up — the behaviour of a QGIS layer
opacity. Not combined with blur or blend modes yet (easy to add: it goes through the same
`drawLayerOpacity`).

A per-feature QGIS effect that must interleave with the features of its own layer (each tree's
shadow falls on the trees drawn before it) cannot be a separate layer. Bake it into the sprite
instead — see `shadow` in `src/style/sprite-icons.ts`.

`patches/tools/apply-symbol-layer-opacity.py` made the edits.
