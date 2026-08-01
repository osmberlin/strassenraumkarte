# Ad hoc image loading in MapLibre

How to supply icons and fill/line patterns that are **not** in the style’s sprite — either a small fixed set registered up front, or an unbounded set generated when the map asks for them. Grounded in MapLibre GL JS APIs and in FMC findings from **tilda-geo-traffic-signs** (TILDA atlas) and **vzk-bw-workspace** (Verkehrszeichen BW).

---

## 1. Why ad hoc loading?

### Problem

Symbol layers reference images by **id** (`icon-image`, also `fill-pattern` / `line-pattern` / `background-pattern`). The usual source of those ids is the style **sprite** (PNG + JSON) baked at build time. That breaks down when:

1. Icon ids are **data-driven and unbounded** (each feature can invent a new id).
2. Icons are **generated** (canvas composite, themed color, user upload) and cannot live in a static sprite.
3. Assets are **SVGs or late-loaded URLs** that the sprite pipeline does not include.
4. You only discover missing ids at **runtime** (broken style, wrong coalesce, typo).

### Why sprites alone are not enough

Sprites are a closed set: every `icon-image` value must already exist, or the symbol does not draw. FMC’s TILDA path merges Mapbox Studio sprites into `public/map-style/sprite{,@2x}.{png,json}` and rewrites the style sprite URL at request time — fine for atlas notes markers and hatch textures, useless for “one icon per unique sign-stack JSON”.

### Solution space

| Strategy | When | FMC example |
| --- | --- | --- |
| **Style / sprite fix** | Id belongs in the built sprite | TILDA `MapboxStyles` merge + `/api/map-style` sprite rewrite |
| **Proactive `addImage`** | Small, **known** set of ids | VZK `useMapImages` → `NO_SIGN_ICON` placeholder |
| **Reactive missing-image hook** | **Dynamic / unbounded** ids | VZK sign supports: `icon-image` = aggregation JSON → canvas → `addImage` |
| **Dev warn only** | Audit missing ids; do not generate | TILDA `RegionMap` `console.warn` on `styleimagemissing` |

---

## 2. MapLibre APIs (verified)

All claims below follow the [Map](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/) class docs.

| API | Role |
| --- | --- |
| [`map.loadImage(url)`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#loadimage) | Fetch PNG / WebP / JPG (CORS required). Returns `{ data }` for `addImage`. **Not SVG.** |
| [`map.addImage(id, image, options?)`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#addimage) | Register runtime image usable like a sprite icon (`HTMLImageElement`, `ImageData`, `ImageBitmap`, or `{width,height,data}`). Options include `pixelRatio`, stretch/content for `icon-text-fit`. |
| [`map.hasImage(id)`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#hasimage) | True if id exists in sprite **or** was added at runtime. |
| [`map.getImage`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#getimage) / [`listImages`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#listimages) | Inspect a registered image or list all ids (sprite + runtime). |
| [`map.removeImage(id)`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#removeimage) / [`updateImage`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#updateimage) | Drop or replace a registered image. Prefer `updateImage` over a second `addImage` for the same id. |
| [`map.setMissingStyleImageResolver(fn)`](https://maplibre.org/maplibre-gl-js/docs/API/classes/Map/#setmissingstyleimageresolver) | **MapLibre v6+** preferred way to supply missing icons/patterns (sync or async). Map awaits the promise before treating the id as missing. |
| [`styleimagemissing`](https://maplibre.org/maplibre-gl-js/docs/API/type-aliases/MapEventType/) | Fired when an icon/pattern is missing. On **v5**, listeners commonly call `addImage` (with race caveats for async). On **v6**, listeners **cannot** resolve the *current* request via `addImage` — use the resolver; the event remains for observation of still-unresolved ids. |

Style Spec: [Sprite](https://maplibre.org/maplibre-style-spec/sprite/) (`.json` + `.png`, `@2x`, multi-sprite `spriteId:imageId` references) and [`icon-image`](https://maplibre.org/maplibre-style-spec/layers/#layout-symbol-icon-image). Runtime `addImage` ids are unprefixed names in the shared image manager — keep naming consistent with any multi-sprite prefixes you use in the style.

Official examples:

- [Add an icon to the map](https://maplibre.org/maplibre-gl-js/docs/examples/add-an-icon-to-the-map/) — `load` → `loadImage` → `addImage` → symbol layer.
- [Generate and add a missing icon](https://maplibre.org/maplibre-gl-js/docs/examples/generate-and-add-a-missing-icon-to-the-map/) — `setMissingStyleImageResolver` builds pixel data from the requested id.

### Version split (important)

| Stack | How to resolve missing images |
| --- | --- |
| **MapLibre GL JS 5.x** (TILDA `5.24.0`, VZK `5.23.0` today) | `map.on('styleimagemissing', …)` + `addImage`. Async handlers can race: MapLibre may re-fire or skip the frame until the image exists — always `hasImage` before `addImage`. |
| **MapLibre GL JS 6.x** | Prefer `setMissingStyleImageResolver`. Migrate per [v5→v6 guide](https://github.com/maplibre/maplibre-gl-js/blob/main/docs/guides/v5-to-v6-migration-guide.md). `styleimagemissing` becomes “still missing after resolver”. |

PR context: [`setMissingStyleImageResolver`](https://github.com/maplibre/maplibre-gl-js/pull/7850) exists specifically because async `styleimagemissing` + late `addImage` often finished **after** MapLibre had already decided the image was missing for that pass. Related history: [ImageManager / styleimagemissing race (#2164)](https://github.com/maplibre/maplibre-gl-js/issues/2164).

---

## 3. Proactive registration (fixed ids)

### Problem

A small set of icons (placeholders, legend markers, default coalesce targets) must exist **before** symbol layers paint, so you never flash missing icons.

### Solution (VZK `useMapImages`)

Register in a `useEffect` once the map instance exists. Raster URLs use `loadImage`; SVGs use `HTMLImageElement` + `pixelRatio` because `loadImage` only accepts png/webp/jpg.

```ts
// Pattern from vzk-bw-workspace/frontend/src/hooks/useMapImages.ts
for (const { name, url, width, height, options } of images) {
  if (map.hasImage(name)) continue

  const isSvg = url.endsWith('.svg') || url.startsWith('data:image/svg+xml;')
  if (isSvg) {
    const pixelRatio = window.devicePixelRatio
    const img = new Image(pixelRatio * (width ?? 20), pixelRatio * (height ?? 20))
    img.onload = () => {
      if (!map.hasImage(name)) map.addImage(name, img, { pixelRatio, ...options })
    }
    img.src = url
  } else {
    const { data } = await map.loadImage(url)
    if (!map.hasImage(name)) map.addImage(name, data, options)
  }
}
```

Usage: register `NO_SIGN_ICON` before the sign-supports symbol layer references aggregations that may fall back to it.

**Why `useEffect`:** `useMap()` is often undefined on first render; load is async — never call `addImage` during render. No cleanup is usual: images stay until the style is replaced.

Documented in TILDA’s skill notes: `tilda-geo-traffic-signs/.agents/skills/react-map-gl/references/map-images-proactive.md`.

---

## 4. Reactive / on-demand generation (unbounded ids)

### Problem

VZK vector tiles expose an `aggregation` property (JSON describing stacked sign codes + optional bearings). The symbol layer uses that string as `icon-image`. Every distinct aggregation is a **new** image id — pre-registering is impossible.

### Solution (v5 pattern used in VZK today)

1. Set `'icon-image': ['get', 'aggregation']` on the symbol layer.
2. On `styleimagemissing`, parse `event.id`, generate a canvas (`generateSignSupportImage`), then `addImage(id, image)`.
3. Guard with `hasImage(id)` because MapLibre may emit the event again while the async work runs.

```ts
// Intended pattern (TILDA skill). VZK SignSupportsLayer currently
// registers in the render body — do not copy that; use useEffect + off().
useEffect(() => {
  if (!map || !mapLoaded) return

  const onMissing = async ({ id }: MapStyleImageMissingEvent) => {
    if (map.hasImage(id)) return
    const aggregation = JSON.parse(id)
    const image = await generateSignSupportImage(aggregation)
    if (image && !map.hasImage(id)) map.addImage(id, image, {})
  }

  map.on('styleimagemissing', onMissing)
  return () => map.off('styleimagemissing', onMissing)
}, [map, mapLoaded])
```

Generation sketch (`generateSignSupportImage`): load per-code SVGs into `Image`s, lay them out on a canvas (columns per sign group, orientation arrow, padding), return the canvas/`ImageData` for `addImage`.

### Solution (v6-forward)

```ts
map.setMissingStyleImageResolver(async (id) => {
  if (id === 'null' || id === '') return
  const aggregation = JSON.parse(id)
  const image = await generateSignSupportImage(aggregation)
  if (image) map.addImage(id, image, {})
})
```

Or return `{ image, options }` if using the form documented in the PR; current published docs show calling `addImage` inside the resolver before the promise settles.

Official sync generation example (id encodes RGB): [Generate and add a missing icon](https://maplibre.org/maplibre-gl-js/docs/examples/generate-and-add-a-missing-icon-to-the-map/).

---

## 5. Dev-only missing-image audit (TILDA)

When icons **should** come from the sprite, do not generate — log:

```ts
// RegionMap.tsx (tilda-geo-traffic-signs) — abbreviated
useEffect(() => {
  if (!mainMap || !isDev) return
  const handler = (event: MapStyleImageMissingEvent) => {
    if (event.id === 'null') return // coalesce / "none" fallbacks can emit "null"
    console.warn('Missing image', event.id)
  }
  mainMap.on('styleimagemissing', handler)
  return () => mainMap.off('styleimagemissing', handler)
}, [mainMap])
```

Fix the style build or data; the symbol simply stays blank until the sprite contains the id.

---

## 6. Conditional / data-driven icons

When `icon-image` is an expression:

- Missing property → missing id → missing-image hook fires.
- Prefer coalesce: `['coalesce', ['get', 'icon'], 'default-marker']`.
- Register `default-marker` proactively or put it in the sprite.
- Skip sentinel ids (`'null'`, `''`) in handlers.

---

## 7. React / react-map-gl lifecycle

| Do | Don’t |
| --- | --- |
| Subscribe in `useEffect` after map (and preferably style) is ready; `off()` on unmount | `map.on('styleimagemissing')` in the **render body** (VZK bug: duplicates listeners every render) |
| Guard `hasImage` before every `addImage` | Assume one event = one successful paint for async loads (v5) |
| Re-register images after **style reload** if the map instance is reused (`reuseMaps`) | Expect runtime images to survive `setStyle` |
| Prefer map callback props for gestures; use `useEffect` only when there is **no** prop (missing-image APIs) | Mix both without cleanup |

TILDA skill: `map-event-handlers.md` — `styleimagemissing` has **no** react-map-gl `<Map>` prop.

---

## 8. Pitfalls checklist

1. **SVG:** `loadImage` rejects SVG — rasterize via `Image` + pass `pixelRatio` into `addImage` or the icons look soft/wrong size.
2. **Async race (v5):** missing event can fire repeatedly until registration completes; always `hasImage` (see also [#2164](https://github.com/maplibre/maplibre-gl-js/issues/2164)).
3. **v6 migration:** stop relying on `styleimagemissing` to *supply* images; switch to `setMissingStyleImageResolver`.
4. **Listener leaks:** subscribe/unsubscribe in effects; never in render.
5. **Sentinel ids:** filter `'null'` / empty from expression fallbacks.
6. **Style replace:** runtime images are tied to the current style; re-add after `setStyle` / basemap swap.
7. **Duplicate `addImage`:** registering an id that already exists errors — guard with `hasImage`, or use `updateImage` when replacing.
8. **Sprite capacity / size:** `addImage` can fail if the image is invalid or the atlas is full; keep generated canvases bounded (VZK caps sign tiles ~100×100 plus padding).
9. **CORS:** external URLs for `loadImage` must allow CORS.
10. **Closed sets → sprites:** if the set is finite and known (notes markers, hatch `stripe_texture`), fix the sprite pipeline instead of runtime generation.

---

## 9. Recommendation (for this repo / FMC-style maps)

1. **Finite style icons** → keep/merge into the sprite (TILDA MapboxStyles pattern).
2. **Small known runtime icons** (placeholders, defaults) → proactive `useMapImages`-style `addImage` on mount.
3. **Unbounded / generated icons** (traffic-sign stacks, color-encoded ids, user art):
   - On **MapLibre 5**: `styleimagemissing` in `useEffect` + `hasImage` + `addImage` (accept possible one-frame miss until load completes).
   - On **MapLibre 6+** (or when upgrading): `setMissingStyleImageResolver` as the primary path; keep `styleimagemissing` only for logging unresolved ids.
4. **Hybrid (VZK in practice):** proactive placeholder (`NO_SIGN_ICON`) **plus** reactive generation for aggregation ids.
5. **During development of sprite-backed styles** → TILDA-style `console.warn` only.

For Straßenraumkarte-style cartography, ad hoc loading is most relevant for **QA markers, legend symbols, or data-driven pictograms** layered on a vector street-space style — not for basemap sprites themselves.
