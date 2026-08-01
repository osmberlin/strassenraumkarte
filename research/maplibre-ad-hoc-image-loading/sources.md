# Research sources

Bibliography for [summary.md](./summary.md). Summaries are factual overviews of what each source covers.

## MapLibre primary documentation

### [Map — addImage / loadImage / hasImage / removeImage / setMissingStyleImageResolver](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/)
**MapLibre GL JS API**

Authoritative method docs: runtime image registration, CORS/`loadImage` format limits (png/webp/jpg), `hasImage` covering sprite + runtime ids, and v6 `setMissingStyleImageResolver` which awaits async resolution before treating an image as missing.

### [MapEventType — styleimagemissing](https://maplibre.org/maplibre-gl-js/docs/API/type-aliases/MapEventType/)
**MapLibre GL JS API**

Documents when `styleimagemissing` fires: icon/pattern needed by the style is missing and (on current docs) no missing-image resolver supplied it. Points to the generate-missing-icon example; notes that event listeners cannot resolve the current request on the v6 model.

### [MapStyleImageMissingEvent](https://maplibre.org/maplibre-gl-js/docs/API/type-aliases/MapStyleImageMissingEvent/)
**MapLibre GL JS API**

Event payload shape: `id` (requested image id) and `type: "styleimagemissing"`.

### [Add an icon to the map](https://maplibre.org/maplibre-gl-js/docs/examples/add-an-icon-to-the-map/)
**MapLibre GL JS examples**

Canonical proactive pattern: on `load`, `await map.loadImage(url)`, `map.addImage(id, image.data)`, then add a GeoJSON source + symbol layer with `icon-image`.

### [Generate and add a missing icon to the map](https://maplibre.org/maplibre-gl-js/docs/examples/generate-and-add-a-missing-icon-to-the-map/)
**MapLibre GL JS examples**

Canonical reactive pattern on current docs (v6): `setMissingStyleImageResolver` parses a prefixed id, generates `Uint8Array` RGBA pixels, `addImage`, then uses `icon-image: ['concat', 'square-rgb-', ['get', 'color']]`.

### [v5 to v6 migration guide — styleimagemissing](https://github.com/maplibre/maplibre-gl-js/blob/main/docs/guides/v5-to-v6-migration-guide.md)
**MapLibre GL JS**

States that in v6, `styleimagemissing` listeners can no longer resolve the current image request by calling `Map#addImage`; migrate suppliers to `Map#setMissingStyleImageResolver`. Resolver may be sync or async; event remains for observing still-unresolved images.

### [PR #7850: setMissingStyleImageResolver](https://github.com/maplibre/maplibre-gl-js/pull/7850)
**maplibre/maplibre-gl-js**

Motivation: async `styleimagemissing` handlers that `fetch` then `addImage` often finish too late for the current missing-image request. Introduces a dedicated resolver MapLibre can await; `styleimagemissing` fires if the resolver does not provide the image.

### [Layers — MapLibre Style Spec](https://maplibre.org/maplibre-style-spec/layers/)
**MapLibre Style Spec**

Defines `icon-image` and pattern paint properties that resolve against style images (sprite + runtime).

## FMC plans & implementation (seed material)

### TILDA skill: `map-images-missing.md`
**Path:** `tilda-geo-traffic-signs/.agents/skills/react-map-gl/references/map-images-missing.md`

Plan/decision table: proactive vs reactive vs sprite fix vs dev-warn. Documents VZK-style `styleimagemissing` + canvas generation, `hasImage` guard, React `useEffect` subscribe/`off`, sentinel `'null'`, and checklist. Notes VZK’s anti-pattern of registering the listener in the render body.

### TILDA skill: `map-images-proactive.md`
**Path:** `tilda-geo-traffic-signs/.agents/skills/react-map-gl/references/map-images-proactive.md`

Documents `useMapImages`: register fixed icon ids before symbol layers render; SVG via `Image` + `pixelRatio`; raster via `loadImage`; when to choose proactive vs `styleimagemissing`.

### TILDA skill: `map-event-handlers.md`
**Path:** `tilda-geo-traffic-signs/.agents/skills/react-map-gl/references/map-event-handlers.md`

States that `styleimagemissing` has no react-map-gl `<Map>` prop — use MapLibre `on`/`off` inside `useEffect`.

### TILDA: `RegionMap.tsx` — `subscribeToMissingStyleImages`
**Path:** `tilda-geo-traffic-signs/app/src/components/regionen/pageRegionSlug/Map/RegionMap.tsx`

Production TILDA handler: in development only, `console.warn` missing image ids; ignores `'null'`; proper effect cleanup. MapLibre `5.24.0`.

### VZK: [`useMapImages.ts`](https://github.com/FixMyBerlin/vzk-bw-workspace/blob/main/frontend/src/hooks/useMapImages.ts)
**vzk-bw-workspace**

Implemented proactive hook: SVG vs raster branch, `hasImage` guards, `addImage` with `pixelRatio` for SVG.

### VZK: `SignSupportsLayer.tsx`
**Path:** `vzk-bw-workspace/frontend/src/components/signs/map/SignSupportsLayer.tsx`

Reactive path: `icon-image: ['get', 'aggregation']`, `styleimagemissing` → `generateSignSupportImage` → `addImage`. Also calls `useMapImages` for `NO_SIGN_ICON`. Currently attaches the missing-image listener in the component body (known leak risk called out in TILDA skill).

### VZK: `generateSignSupportImage.ts`
**Path:** `vzk-bw-workspace/frontend/src/modules/generateSignSupportImage.ts`

Canvas compositor: loads sign SVG assets and orientation arrows, lays out groups/codes, returns drawable image data for `addImage`.

### TILDA: MapboxStyles / mergeSprites
**Path:** `tilda-geo-traffic-signs/app/scripts/MapboxStyles/README.md`

Closed-set alternative: merge Studio sprites into app-hosted `sprite` / `sprite@2x`, rewrite style sprite URL via `/api/map-style`. Used when icons are known at build time (e.g. OSM notes markers, `stripe_texture`).

## Related Mapbox note (format limit)

### [Mapbox: Add an icon to the map](https://docs.mapbox.com/mapbox-gl-js/example/add-image/)
**Mapbox GL JS docs**

Documents the same `loadImage` → `addImage` flow and explicitly warns that SVG is **not** supported by `loadImage` (png/jpg/webp only) — consistent with MapLibre’s `loadImage` parameter docs.
