# Fantasy ink map: design research notes

Scope: second style exploration for Straßenraumkarte (Berlin-Neukölln, OSM via PostGIS + QGIS, zoom 15–20). Target look: hand-drawn black-and-white ink / pencil, fantasy-book map, with optional single accent colour.

Reference images are local-only (`references/web/`, not committed). Sources were checked by search snippets and by viewing the downloaded files. Items marked **(unverified)** could not be confirmed from a primary source.

## Summary

- **Hybrid projection is the norm.** Historical and fantasy city views (Merian, Braun & Hogenberg, Schedel) draw the city in oblique bird's-eye view: houses show roofs and gables, towers and churches stand up, but streets, squares, walls, rivers and field parcels are essentially plan. For us: keep streets, plots and water flat; give buildings a short oblique "roof + facade" read only at higher zoom, and draw landmarks and trees as upright icons.
- **Accent colour is a single-plate technique, not a rule of the genre.** Historic maps mostly use one ink (black) on paper, with a second colour as a sparse highlight (the red monster in the Ebstorf and Carta Marina images, a red-brown area in the Hereford map, red roofs in the Florence woodcut). For a playground-only accent: black ink for everything, one saturated colour reserved for playgrounds, no colour fills elsewhere, and a paper-coloured halo around the accent glyphs.
- **Line vocabulary is short and repeatable.** Parallel hatching for hills and shadow, short wavy ripples for water, dot/stipple for meadows and field texture, tiny lollipop or blob shapes for trees, sharp-edged dark blocks for built mass. Line weight does the hierarchy work: thick outline for walls and major roads, thin hatching for everything else.
- **Procedural precedent exists but is thin for this exact look.** Watabou's Medieval Fantasy City Generator (MFCG) is the closest programmatic reference (Haxe/OpenFL, source reportedly public). QGIS can reach a hand-drawn look with geometry generators plus random offset expressions (Andy Woodruff, 2024). The academic basis is Winkenbach & Salesin 1994 (stroke textures) and Salisbury et al. 1994/1997 (interactive and orientable pen-and-ink hatching).
- **No Tolkien-style OSM renderer found.** The closest precedents are ArcGIS styles ("My Precious", "One Style to Rule Them All", John Nelson / Esri) and Stamen Watercolor/Toner on Stadia Maps (MapLibre). A custom MapLibre/Mapnik style (or QGIS symbology) is the realistic path.

---

## A. Pseudo-3D vs plan view

### Rules of thumb (synthesised from the reference images)

| Element | Typical treatment in the references | Evidence |
|---|---|---|
| Streets, lanes, squares | Plan view. Drawn as white channels between dark building masses. | fi-01, fi-02 (Merian Frankfurt), fi-06 (Avignon) |
| City walls, moats, gates | Plan-view outline with oblique towers or gate-houses. Walls get the heaviest line. | fi-03 (Frankfurt an der Oder), fi-06 |
| Houses in mass | Oblique footprint with a visible roof face and gable ridge; roofs shaded with hatching, but the block reads as one mass. | fi-01, fi-02, fi-07 (Nuremberg) |
| Churches, towers, castles | Always oblique and taller than neighbours. Drawn bigger than houses and frequently with spires. | fi-01, fi-07, fi-08 (Hereford's town icons) |
| Trees | Side-view or three-quarter lollipops, or groups of small blobs in plan-oblique blocks. Never a plan-view circle with a shadow. | fi-03, fi-04 (Tegernsee), fi-06 |
| Gardens, field parcels | Plan view, with dot or hatch fill and small upright trees dotted in the fill. | fi-01, fi-02, fi-04 |
| Rivers, lakes | Plan view with horizontal wave strokes; banks outlined with a thick line; shipping drawn as small upright sails. | fi-01, fi-04, fi-06 |
| Hills, mountains | Oblique (profile) silhouettes with hachure on the shadow side. Used even in plan-view maps. | fi-04, fi-05 (Trier), fi-06 |
| Coasts, sea | Plan-view outline with ripple strokes, sea monsters and ships in profile. | fi-11 (Carta Marina) |

### Rules the references imply for a programmatic version

1. **Light and view direction are fixed.** All historic prints use one oblique view direction (roughly from the south-west in Merian's Frankfurt; from the south in Avignon). Shadow falls to one side and roofs are hatched on the same side.
2. **Anchor at footprint bottom and paint south-to-north.** In all oblique views, objects further away (north) are painted first and objects nearer (south) overlap them. This is the painter's order needed for icons to sit on top of streets without collisions being visible.
3. **Mass housing is a plan block with roof texture.** Individual houses are only drawn when the block is large enough or when the zoom is high. At low zoom, a block should be a flat dark mass with a hatched roof read.
4. **Landmarks are the exception to the plan rule.** Every landmark (church, town hall, castle, bridge gate) is drawn as a larger oblique icon with a visible tower or spire. In MFCG, churches and the temple are separate building types, larger than houses, with a small square beside them, and large buildings get extra detail (cupolas) (see the watabou devlog quotes in section D).
5. **Trees are always upright.** Even in a plan-view map, the references switch trees to side view. The Tegernsee plate uses small lollipops; the Frankfurt an der Oder plate uses dense blobs in plan.

### Watabou and Dyson Logos (programmatic handling)

- **Watabou MFCG:** trees are hidden by default and placed in city greens, empty courtyards, and between farm fields. Version 0.9.2 (Feb 2023) made them puffier and smaller and switched to a faster placement method; comments on 0.9.1 said the originals were far too large (some over 25 m scale). Regular buildings are footprints with roof shading that depends on storey count; large buildings get cupolas. Source: [Watabou devlog 0.9.1](https://watabou.itch.io/medieval-fantasy-city-generator/devlog/345262/091-trees-and-other-visual-changes), [Patreon 0.9.2 post](https://www.patreon.com/posts/79147510), [0.11.4 forests devlog](https://watabou.itch.io/medieval-fantasy-city-generator/devlog/817711/0114-forests). The devlog text is secondary, so check the source code for exact draw order.
- **Dyson Logos:** the search returned his general mapping tutorial (side view first, then the rest of the map) and his InstaDyson hatching and floor-grid tiles, not a city-icon method. See [dysonlogos.blog](https://dysonlogos.blog/2020/06/10/instadyson-in-action/) and the [2011 tutorial](https://dysonlogos.blog/2011/04/24/a-dyson-mapping-1-2-3-tutorial/). A separate creator, JP Coovert, is cited for building up small house-and-tower icons into town clusters. **(unverified: that Coovert's approach is what Dyson uses for cities)**

### Open question for A

- How much oblique detail is legible at z15–z16 for a 1 m OSM building footprint? Probably none; the roof read may need to appear from z17 or z18.

---

## B. Monochrome plus accent colour

### Examples found

| Example | Accent | What it shows |
|---|---|---|
| Ebstorf world map detail (fi-10) | Red for a monster and red-tinted banding, rest flat ochre/brown watercolour over black ink outlines | Accent used sparingly on one creature; the rest is a muted palette, not ink-only |
| Hereford Mappa Mundi c.1300 (fi-08) | Red-brown for Jerusalem and a few annotations; the rest is ink on parchment | Strongest example of "ink plus one colour" as a hierarchy device |
| Carta Marina 1539, Olaus Magnus (fi-11) | Red for a sea serpent and red-letter place names; the rest is coloured woodcut | Accent colour as a signal for a special object |
| Frankfurt Merian 1628 and 1770 (fi-01, fi-02) | None. Pure engraving; accent is only in the border cartouches (white) | Black-only is a legitimate complete style |
| Wilderland / Tolkien (not downloaded) | Red place names overprinted on the black map. Source: [Tolkien Gateway / Tolkien Estate](https://irc.tolkiengateway.net/wiki/There_and_Back_Again_(map)) and the search summary below | Accent on labels only, no colour on features |
| Florence Schedel woodcut (fi-09) | Red roofs over black-and-white walls and streets; blue on some roofs | Accent on a surface type (roofs), so the map reads as a red-roof city |

### Rules of thumb

1. **One accent, reserved for one class.** Hereford, Carta Marina and Ebstorf all reserve red for a single item type. Playgrounds could take the accent; nothing else gets saturated colour.
2. **Accent as line or glyph, not fill.** In the references, red appears as a stroke or small glyph (monster body, Jerusalem's outline, place names) more often than as a large fill. Large fills tend to take over the page.
3. **Use tints of the accent for hierarchy, not new hues.** Ebstorf and Florence stay within one or two saturated hues.
4. **Halos.** The Wilderland red names sit on the paper colour; a thin paper-coloured halo keeps them legible over hatching. (Halo as a technique is standard cartographic practice; I have not checked a specific reference for it.)
5. **Printing constraint.** A two-colour (black + spot) job has to choose the spot ink first and then fit tints of black and red. Screen previews differ from spot inks, so check against a proof. Source: [Fiery two-colour mapping](https://help.fiery.com/cws/5.6/en-us/GUID-F56AFE8B-9767-4091-B57C-1C4CA739ADCB.html) (proofing only); general practice notes in the search summary are my own.
6. **Do not rely on colour alone.** Pair the playground colour with a distinct glyph shape, a label, and a legend. (UK government design system guidance: [brand.design-system.service.gov.uk/colour/maps](https://brand.design-system.service.gov.uk/colour/maps).)
7. **Black on black.** Text placed over a black boundary line disappears. Knock out or halo the text. This matters for the playground label on a dark block fill.

### Recommendation for playgrounds

- Plate 1: all features in black ink line and hatch on paper.
- Plate 2: playground glyph only, in one saturated accent (e.g. the same red as the Carta Marina serpent or a muted spot red), with a paper halo.
- No other colour. Water, parks and buildings stay on the paper colour with ink.

---

## C. Line and texture vocabulary

### Table: map element to ink treatment

| Map element | Ink treatment | Reference |
|---|---|---|
| Building roof | Parallel hatch, direction follows roof slope (orientable hatching). Lighter on the lit side. | Salisbury et al. 1997 (orientable textures); fi-01, fi-07 |
| Building mass, dense blocks | Solid black or near-black with white street channels | fi-01, fi-02 |
| Building wall, facade | Single thin outline; no fill | fi-06, fi-07 |
| City wall | Heaviest outline in the map; short tower squares on the line | fi-03, fi-06 |
| Major street | White channel with thin dark edges, or double line | fi-01, fi-06 |
| Minor street / lane | Single thin line or no outline | fi-01 |
| Meadow, grass | Stippling or dotted field fill, with sparse upright tufts | fi-04 (Tegernsee), fi-01 field parcels |
| Field parcel | Hatch in a fixed direction per parcel, or plan grid of small squares | fi-03, fi-04 |
| Tree | Upright lollipop (trunk plus crown), or scalloped blob in plan-oblique groups | fi-04, fi-06 |
| Forest | Dense scalloped blob outline with dark fill on the shadow side | fi-04 (south slope) |
| Hill, mountain | Parallel hachure on the shadow side, lighter on the light side | fi-04, fi-05 |
| River | Two dark bank lines; horizontal wave strokes (short dashes) inside | fi-01, fi-04 |
| Water body (lake, sea) | Ripple lines following the outline, spacing increasing away from shore | fi-04, fi-11 |
| Sea monster / ship | Upright profile, one accent colour at most | fi-11 |
| Playground (accent candidate) | Single glyph, accent colour, paper halo | Section B |
| Bench, fountain | Small upright icon or dot | Frankfurt plates (small square icons) |
| Lettering | Upright serif capitals for district and city names; italic or script for water and landscape names | fi-01 (roman caps), fi-03 ("FRANCOFVRTVM ad Viadrum"), fi-03 (cursive "Frankfurt an der Oder") |
| Cartouche / title | Ornate scroll frame; the Merian plates use these for the title and key | fi-01, fi-02 |
| Compass rose | Eight-point star, dark and light halves | fi-02 (compass rose, right side), fi-04 (compass in inset); fi-01 has a sundial/instrument bottom-centre |
| Paper and texture | Off-white or slightly warm paper; edge wear and toning visible on the Frankfurt 1770 and Frankfurt an der Oder prints | fi-02, fi-03 |
| Sepia vs black | Historic plates are black-only or ink-plus-watercolour. Sepia is a common compromise on fantasy maps; the references do not show a strong preference. | fi-08, fi-10 |

### Line weight hierarchy (suggested from references)

1. City walls and water banks: thickest.
2. Building outlines and major streets: medium.
3. Hatching, minor streets, field lines: thin.
4. Ripples and stipple: thinnest, lowest density.

### Hand jitter

Random offsets of a few tenths of a pixel at each vertex, with occasional slightly varying line width, give the human-drawn feel without visible wobble. Andy Woodruff's QGIS method relies on exactly this idea: "many small random errors". See section D.

---

## D. Procedural generation precedents and techniques

### Tools and projects

| Tool / project | What it does | Notes | URL |
|---|---|---|---|
| Watabou Medieval Fantasy City Generator (MFCG) | Procedural walled city, Voronoi districts, hand-styled buildings, trees, churches | Haxe/OpenFL. Developer says source is public; a fork named TownGeneratorOS is cited (**unverified** whether this is the official repo) | [itch.io](https://watabou.itch.io/medieval-fantasy-city-generator) |
| Watabou Perilous Shores | Procedural region / coast map | Not a city tool. Has a "Collection of styles" devlog; I did not confirm a black-and-white ink preset | [itch.io](https://watabou.itch.io/perilous-shores) |
| Azgaar Fantasy Map Generator | Whole-world fantasy map, many style presets | No ink or sketch preset confirmed in the README; the Roll20 summary mentions style presets from cyberpunk to watercolour | [GitHub](https://github.com/Azgaar/Fantasy-Map-Generator) |
| rough.js | Hand-sketched SVG/Canvas shapes, hachure/cross-hatch fills, roughness and bowing parameters | MIT. Good for icons and cartouches; use the worker build for large maps | [roughjs.com](https://roughjs.com/), [npm](https://www.npmjs.com/package/roughjs) |
| Rough Notation | Animated annotations on web content | Less useful for maps | [roughnotation.com](https://roughnotation.com/) (**unverified URL**) |
| Winkenbach & Salesin 1994 | "Computer-generated pen-and-ink illustration": stroke textures give tone with line only, resolution-dependent | SIGGRAPH 1994, pp. 91–100 | [UW GRAIL project](https://grail.cs.washington.edu/projects/cg-illus), [DOI 10.1145/258734.258890](https://www.doi.org/10.1145/258734.258890) |
| Salisbury et al. 1994 | "Interactive pen-and-ink illustration": user paints stroke textures, computer draws strokes | SIGGRAPH 1994, pp. 101–108 | [UW GRAIL](https://grail.cs.washington.edu/projects/int-illus), [PDF (UC Davis)](https://web.cs.ucdavis.edu/~ma/SIGGRAPH02/course23/notes/papers/Salisbury94.pdf) |
| Salisbury et al. 1997 | "Orientable textures for image-based pen-and-ink illustration": hatching follows surface orientation | Relevant to roof hatching | [PDF (UC Davis)](https://www.cs.ucdavis.edu/~ma/SIGGRAPH02/course23/notes/papers/Salisbury97.pdf) |
| Andy Woodruff, "Hand-drawn and antique styles with QGIS" (2024) | QGIS technique: random jitter in symbols via expressions; geometry generator; layered strokes with multiply blend | Most directly applicable. Read the full post; the summary I saw covered only the first sections | [andywoodruff.com](https://andywoodruff.com/posts/2024/qgis-hand-drawn-maps/) |
| QGIS "Sketchy Line" style (Tim Sutton) | Sketchy line based on randomised offset expression | CC0 | [QGIS plugin hub](https://plugins.qgis.org/styles/149/) (**unverified: ID is the Woodruff/Tim Sutton style page as surfaced by search**) |
| QGIS "Sketchy styles" set | Buildings, water, paths, trees, grasslands; inspired by an Esri article | Slow on large layers | [QGIS plugin hub](https://plugins.qgis.org/styles/77/) (**unverified mapping of style set to URL**) |
| Expressions Plus plugin (`jitter_geometry()`) | Vertex jitter for QGIS geometries | | [QGIS plugins](https://plugins.qgis.org/plugins/) |
| MapLibre / Maputnik | Writing custom vector tile styles | Needed for an OSM-hosted web tile version | [maplibre.org](https://maplibre.org/), [maputnik.github.io](https://maputnik.github.io/) |
| Stamen Watercolor / Toner | Watercolor raster look and black-only Toner on OSM data; now hosted by Stadia Maps on MapLibre | Precedent for "map style as art on OSM"; CC BY 4.0 for tiles | [Stadia Maps announcement](https://stadiamaps.com/news/stamen-design-and-stadia-maps/) |
| ArcGIS "My Precious" (John Nelson, Esri) | ArcGIS style imitating Christopher Tolkien / Pauline Baynes maps | Author criticises mechanical stamping of mountain and forest symbols over large areas. Not for OSM | [Maproom blog 2018](https://www.maproomblog.com/2018/09/maps-middle-earth-style-by-hand-and-by-arcgis/) |
| ArcGIS "One Style to Rule Them All" (2024) | Fantasy map elements applied to real geodata, far smaller than My Precious | | [Maproom blog 2024](https://www.maproomblog.com/2024/02/one-map-to-rule-them-all-fantasy-map-design-elements-in-arcgis-pro/) |

### Notes on the techniques

- **Random jitter as the core.** Woodruff's point is the same one the NPR literature makes: small systematic randomness, not large noise, makes computer output look hand-made. Use `rand()` / `randf()` for width, offset, rotation and colour jitter in QGIS expressions.
- **Layered strokes.** Two or three copies of a line with slightly different widths and offsets, multiply blend, gives a sketchy outline cheaply. (Geometry Generator wiki description.)
- **Stroke textures instead of fills.** Winkenbach & Salesin's idea is to choose a texture by desired tone and let the stroke pattern carry the tone. For roofs this is more convincing than a flat grey fill.
- **Paper texture.** A low-opacity multiply raster over the whole map (Woodruff and Stamen Watercolor both do this in some form).

### Gaps

- I did not find a published, documented pen-and-ink renderer for OSM data. The closest is the QGIS approach above.
- I did not find a Watabou-style OSM generator, nor a QGIS or MapLibre style that combines oblique buildings with plan streets.

---

## Reference examples

Downloaded to `references/web/`. Verified by viewing each file. Source and licence from the Wikimedia Commons API (`extmetadata`).

| # | Title | Author / date | URL | Local file | Notes |
|---|---|---|---|---|---|
| 01 | Francofurti ad Moenum, bird's-eye plan (1628 plate) | Matthäus Merian d.Ä., 1628 | [Commons](https://commons.wikimedia.org/wiki/File:FfM-Vogelschau-1628.jpg) | `fi-01-merian-frankfurt-1628-vogelschau.jpg` | Gold standard for the hybrid view: oblique houses, plan streets, oblique towers, trees as small blobs. Public domain. |
| 02 | Frankfurt am Main, Merian 1770 reissue | Merian, 1770 reissue | [Commons](https://commons.wikimedia.org/wiki/File:Frankfurt_Am_Main-Merian1770-MFHK-Komplett.jpg) | `fi-02-merian-frankfurt-1770-komplett.jpg` | Same plate as 01 in later printing; useful for compare of line weight. Public domain. |
| 03 | Francofurtum ad Viadrum (Frankfurt an der Oder) | Caspar Merian | [Commons](https://commons.wikimedia.org/wiki/File:Caspar_Merian_-_Francofurtum_ad_Viadrum.jpg) | `fi-03-merian-francofurtum-ad-viadrum.jpg` | Small town in a stricter oblique view; plan blocks with dark roof hatching; tree clusters in plan; numbered key. Public domain. |
| 04 | Geometrischer Grundriss des Stifts Tegernsee | Matthäus Merian, 1644 | [Commons](https://commons.wikimedia.org/wiki/File:Tegernsee_mit_Kloster_Kupferstich_von_Merian_1644.jpg) | `fi-04-merian-tegernsee-1644.jpg` | Best for line vocabulary: hachure hills, lollipop and blob trees, wave-line lake, cartouches and compass rose. Public domain. |
| 05 | Treverīs, hand-coloured | Braun & Hogenberg, Civitates Orbis Terrarum, 1572 | [Commons](https://commons.wikimedia.org/wiki/File:Braun&Hogenberg_Trier_1572.jpg) | removed (see Commons link) | Panoramic bird's-eye with hand colour. Shows hachured hills and a dense roof mass. Public domain. |
| 06 | Avignon, hand-coloured | Georg Braun & Franz Hogenberg, 1575 | [Commons](https://commons.wikimedia.org/wiki/File:Braun_Hogenberg_Civitates_orbis_terrarum_Avignon_1575.jpg) | `fi-06-braun-hogenberg-avignon-1575.jpg` | Strong plan-street grid, oblique towers and palace; trees as small lollipops on the left; accent colour as local wash. Public domain. |
| 07 | Nürnberg, view from the Nuremberg Chronicle | Hartmann Schedel, 1493 | [Commons](https://commons.wikimedia.org/wiki/File:Hartmann_Schedel_-_Nuremberg_Chronicle,_Page_100_-_View_of_the_city_of_Nuremberg_-_WGA20964.jpg) | `fi-07-schedel-nuremberg-1493-view.jpg` | Woodcut in pure black-and-white. Oblique walls and towers, hatched roofs, tight tower silhouettes. Best reference for a monochrome, woodcut-texture town. Public domain. |
| 08 | Hereford Mappa Mundi (detail / full, c.1300) | Unknown medieval illuminator | [Commons](https://commons.wikimedia.org/wiki/File:Hereford_Mappa_Mundi_1300.jpg) | removed (see Commons link) | Ink-on-parchment with a red-brown accent area (commonly read as Jerusalem; not verified from the image); town glyphs in small oblique icons. Public domain. |
| 09 | Florenca, colour woodcut (Schedel) | Hartmann Schedel, 1493 (coloured copy) | [Commons](https://commons.wikimedia.org/wiki/File:Colored_woodcut_town_view_of_Florence.jpg) | removed (see Commons link) | Coloured woodcut; red roofs over black walls. Shows accent-on-surface-type. **Licence: CC BY-SA 4.0, attribution to Bas van Hout required if reused.** |
| 10 | Ebstorf world map, south detail | Ebstorf Mappa Mundi, c.1300 | [Commons](https://commons.wikimedia.org/wiki/File:Detail_(south)_ebstorf_world_map.jpg) | removed (see Commons link) | Ink outlines with flat watercolour; red monster as sole saturated accent; wave bands for water. Public domain. |
| 11 | Carta Marina, fragment (Olaus Magnus, 1539) | Olaus Magnus, 1539 | [Commons](https://commons.wikimedia.org/wiki/File:Fragment_of_Carta_Marina_map_by_Olaus_Magnus_in_1539.jpg) | removed (see Commons link) | Woodcut sea with ripple lines and ships; red sea serpent as accent; small coloured town icons. Public domain. |

### Referenced but not downloaded (no free image file found, or copyright-restricted)

| # | Title | Author | URL | Notes |
|---|---|---|---|---|
| 12 | Medieval Fantasy City Generator (screenshots) | Watabou | [itch.io](https://watabou.itch.io/medieval-fantasy-city-generator) | Devlog pages did not yield direct image URLs in my attempt. Check devlog images manually. |
| 13 | Ankh-Morpork "The Streets of Ankh-Morpork" | Stephen Briggs (concept), Stephen Player (drawn), 1993 | [Wikipedia](https://en.wikipedia.org/wiki/The_Streets_of_Ankh-Morpork) | Copyrighted. Good for plan city with ink lettering; not downloaded. |
| 14 | Middle-earth / Wilderland maps | J.R.R. Tolkien / Pauline Baynes | [Tolkien Gateway](https://irc.tolkiengateway.net/wiki/There_and_Back_Again_(map)) | Copyrighted. Relevant for red place names over black. |
| 15 | Mike Schley Cities / Inks style (ProFantasy) | Mike Schley | [ProFantasy Symbol Set 5](https://profantasy.com/products/ss5.asp) | Commercial symbol set; shows the "Inks" black-and-white setting. |
| 16 | Dyson Logos city and dungeon maps | Dyson Logos | [dysonlogos.blog](https://dysonlogos.blog/) | Copyrighted. |
| 17 | Jared Blando, How to Draw Fantasy Art and RPG Maps (book) | Jared Blando | [Publisher listing](https://www.bearpondbooks.com/book/9781440340246) | Book; covers iconography for towns, fortresses, bridges. |
| 18 | Witcher 3 hand-inked map (Impractical Cartographer) | Impractical Cartographer | Not located | Academic paper mentions a hand-inked stylised version; exact map unverified. |
| 19 | Caspar Merian Frankfurt, Städel 1646 | Unknown after Merian | [Städel](https://sammlung.staedelmuseum.de/en/work/view-of-frankfurt-am-main) | Not downloaded; Merian prints are already covered. |
| 20 | Andy Woodruff, QGIS hand-drawn maps (2024) | Andy Woodruff | [andywoodruff.com](https://andywoodruff.com/posts/2024/qgis-hand-drawn-maps/) | Technique source (section D). |

---

## Open questions

1. **Zoom-dependent detail.** At z15–16 a city block is a few pixels. Which elements can carry the look at this scale (roof hatching, tree blobs, wall lines) and which need to switch on at z17+?
2. **Oblique buildings from OSM footprints.** OSM has footprints and sometimes `building:levels` or `height`. Can we extrude a fake oblique facade from the footprint in QGIS or MapLibre without a 3D engine? Or do we need to pre-render sprites?
3. **Accent colour choice.** Which red or colour to reserve for playgrounds, and does it compete with the existing styling (the current QGIS style has its own palette)?
4. **Procedural vs hand-placed landmarks.** Churches, town hall and the Neukölln castle-style ruins (if any) could be hand-drawn icons. Which features can be automatic?
5. **Watabou licence.** The MFCG code is reportedly public, but I did not find a licence file. Check before reusing any code.
6. **Full Woodruff post.** Only the first sections were visible. Read the full 2024 post for the downloadable styles and the expression set.
7. **Dyson Logos city method.** The city-icon tutorial I was looking for was not located. Check his blog or Patreon directly.
8. **Hand-jitter stability.** Random offsets must be seeded per feature (e.g. OSM id) so tiles do not change between renders.
9. **Print vs web.** Does the target output need a spot-colour print proof, or is it screen-only? This decides whether section B's two-plate approach is worth the extra work.
