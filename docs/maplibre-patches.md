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
