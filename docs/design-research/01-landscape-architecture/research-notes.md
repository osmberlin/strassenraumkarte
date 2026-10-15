# Landscape-architecture site plans: design research notes

Research for restyling Straßenraumkarte (OSM-based street-space map, Berlin-Neukölln) toward the look of landscape-architecture site plans / rendered masterplans ("Lageplan Landschaftsarchitektur", "Freiraumplanung", "Gestaltungsplan", "illustrative site plan"). Target: generate the look from the data pipeline (PostGIS + QGIS), not by post-processing images.

Local reference images are in `references/web/` (not committed; copyright). Hex values in the palette were measured from those downloads where marked; everything else is marked as estimate or general knowledge.

## Summary

- **The tree-canopy vocabulary is the most distinctive part of the style.** Hand-drawn and historical plans build canopies from clusters of scalloped or cloud-like arcs, with a darker shadow side and a light edge, plus a small trunk dot. Modern rendered plans use aerial-photo cutouts instead; these are not procedural and do not transfer to our pipeline directly.
- **Palette is earthy and muted in historical and hand-coloured plans** (sage, olive, sand, ochre, warm grey, paper-cream background). **Modern Photoshop-rendered plans are often saturated green**, so "pastel" is only half-confirmed: the historical references support it, the modern tutorial output does not.
- **Buildings read as the contrast element**: light fill (white, pale grey, cream) with a crisp dark outline, and sometimes a warm roof or wall accent (pink-terracotta in the Schlossgarten and Richmond plans). A hard cast shadow is common in modern renders, usually offset in one fixed direction.
- **Shadow production is a layer recipe**: a building layer, a shadow layer made near-black with Levels and set to Multiply, softened with Smudge, then a tinted colour layer on Overlay. This recipe maps well to a fixed-azimuth offset of footprints in SQL or QGIS.
- **Line weight hierarchy** (from search snippets, not verified in a primary source): nearer or taller elements get heavier lines (buildings, trees), while paving joints and hatch patterns get the lightest weight. The scalability of this for our map (z15–20) is still open.

## Style attributes

### Palette (hex)

Measured values come from the dominant-colour histograms of the downloaded scans (`magick -colors 8`). Scans carry paper tone and a colour cast, so treat them as approximate. "Estimate" means read off the image by eye.

| Element | Hex | Source | Notes |
|---|---|---|---|
| Lawn / meadow, grey-sage | `#798876` | measured, Baltard 1817 | Dominant mid tone of the lawns |
| Lawn / meadow, light olive | `#A8A788` | measured, Schlossgarten Gestaltungsplan | Open grass |
| Meadow, pale green-grey | `#BDC29B` | measured, Vaux/Olmsted 1868 | Park meadow |
| Lawn, saturated olive (modern) | `#73893F`, `#8B9968` | measured, Hogrefe/Visualizing Architecture final | Overlay-tinted, not pastel |
| Canopy dark | `#302F26`, `#484533` | measured, Schlossgarten, Baltard | Shadow side of crowns, dense masses |
| Canopy mid | `#696953`, `#76725C` | measured, Schlossgarten, Baltard | Crown body |
| Canopy light / highlight | `#959171`, `#A8A788` | measured, Schlossgarten | Lit side or edge |
| Canopy, warm ochre (watercolour) | `#94712C`, `#B09758` | measured, Latrobe Richmond | Warm watercolour crowns |
| Canopy, deep (modern) | `#25291B`, `#3B461F` | measured, Hogrefe final | Dark olive |
| Sand / paving, light | `#DAC798`, `#D8D0AA` | measured, Schlossgarten, Vaux/Olmsted | Plazas, sandy paths |
| Sand / road, ochre | `#C6B892`, `#C1A97C`, `#C7AA7F` | measured, Baltard, Olmsted | Roads and paths |
| Building fill, light grey-cream | `#CAC1A1` | measured, Baltard hangar | Hatched or flat fill |
| Building fill, white | `#F2F2EE` (estimate) | visual, Hogrefe | Crisp white pavilion |
| Roof / wall accent, pink-terracotta | `#C98C7A` (estimate) | visual, Schlossgarten, Latrobe | Hand-tinted building masses |
| Water, blue-grey | `#7FA7B5` (estimate) | visual, Baltard Seine | Watercolour blue, flat |
| Water, dark pond | `#25291B`-`#3B461F` range (estimate) | visual, Hogrefe | Pond reads near-black in modern renders |
| Shadow, modern | `#25291B` multiplied at 60–90% (estimate) | visual, Hogrefe | Black shadow set to Multiply |
| Shadow, cool | blue-grey (LandFX claim, not sampled) | secondary source | Recommended in LandFX Part 4 snippet |
| Paper / background, cream | `#F0E6DB` | measured, Vaux/Olmsted | Historical plans |
| Paper / background, grey-blue scan | `#D2D7D0` | measured, Latrobe | Scan colour cast; ignore |

Palette recommendation for our first test: lawn `#9AA58A`, canopy dark `#4C4A39`, canopy mid `#7C7A60`, canopy highlight `#A8A788`, sand `#DAC798`, road `#C6B892`, building fill `#F2F2EE`, building outline `#3A3A34`, roof accent `#C98C7A`, water `#8FA9B3`, shadow `#25291B` at 35–50% multiply. These are proposals based on the measured values above, not sampled from one plan.

### Line weights

Sources are search snippets (a Frankfurt University drawing brief, a general architectural guide) and general practice. Not verified against a primary graphic standard.

- **Hierarchy**: nearer or taller elements get the heaviest line. Trees and buildings are the heaviest, then walls and curbs, then planting beds and furniture, and paving joints, hatch patterns and material hatching are the lightest. Property boundaries may take heavy dashed lines.
- **Proposed starting weights for our map** (to tune at z17–19):
  - Building outline: 0.35–0.5 pt, dark grey `#3A3A34`
  - Tree crown outline: 0.15–0.25 pt, or none (fill only)
  - Trunk dot: 0.6 pt diameter, dark
  - Paving joints: 0.1 pt, low opacity
  - Road edges: 0.2 pt
  - Kerb / fence: 0.2–0.3 pt

### Textures

- **Hand-drawn plans** use wash gradients (watercolour) with dense hatch or stipple inside tree masses. Baltard and Latrobe show clear wash edges and darker dabs where crowns overlap.
- **Central Park 1868 map** (Vaux/Olmsted) uses stipple for shrubs and tree clusters, and tinted fields for lawns, which is a useful precedent for a "printed" look.
- **Modern Photoshop renders** use photo textures (aerial grass, tree cutouts) with Multiply and Overlay layers. This is not procedural.
- **Paper texture** is a noise overlay with about 5–10% opacity. Optional; test whether it helps at print scale.
- **Paving patterns** are shown as module joints around the perimeter of a paved area, not as fills, when the area is secondary. Full modules are drawn for primary circulation.

### Shadows

- **Direction**: one fixed sun azimuth for the whole sheet, checked against the north arrow. Visualizing Architecture advises matching the model shadow direction to the aerial photo.
- **Construction**: a shadow layer made from the building silhouette offset along the azimuth (or extruded in shadow projection), then Levels to make it solid black, then Smudge at about 90% strength to soften the far edge, then Multiply at reduced opacity.
- **Darkest where it meets the building**, fading out away from it (VA tutorial).
- **Tree shadows**: Clemson LARC 8120 brief names shadow projection as a grading criterion for trees. Tree shadows are drawn from the canopy outline offset along the azimuth. Shadow length is about the tree height times the sun's tangent.
- **Colour**: LandFX (search snippet) recommends cool, usually blue, shadows, not neutral black. Not verified against a sample.

### Tree symbol vocabulary

Constructions are described from the references and tutorial snippets. Items 1–3 are visible in the downloaded plans; items 4–8 come from text sources.

1. **Scalloped / cloud outline** (Latrobe Richmond, Central Park): crown outline is a chain of arcs, one per bump. Procedural: a circle with radius perturbed by 2–3 octaves of noise, or a union of jittered circles, with the outline drawn at a fixed bump size.
2. **Two-tone mass with dark shadow side** (Schlossgarten, Baltard): a light crown cap on a darker lower crescent, offset away from the light direction.
3. **Stipple / dot cluster** (Central Park 1868): random dots within the canopy polygon, density varying with crown size. Procedural: Poisson-disc points in the polygon.
4. **Concentric rings** (CAD tree symbol packs): crown circle, optional inner circle for a dense-foliage species. Used for species difference, not realism.
5. **Conifer as narrow spike or stacked triangles** (Schlossgarten, search snippet): narrow crown with a point; plan view as a small triangle or ellipse.
6. **Translucent overlap** (LandFX snippet): crowns drawn at 60–80% opacity so overlapping canopies show. Achieved with Multiply or by drawing each crown at reduced alpha.
7. **Depth layering** (Archez blog snippet): background trees smaller, slightly desaturated, at 70–80% opacity; midground trees at full colour.
8. **Photo-cutout canopy** (VA tutorial, Hogrefe final): aerial photo tree texture masked into the crown outline. Not procedural.

Crown size rule (search snippets): crown diameter is the primary drawing dimension. Symbols are sized to the crown, not to the trunk.

### Lawn vs meadow

- **Lawn**: flat, light olive, sometimes with a slight mown-stripe texture. In modern renders a saturated green.
- **Meadow / rough grass**: darker, broken, with stipple or small dabs. Shown in the Hogrefe and Central Park references as darker green patches with lighter edges.

### Shrubs and hedges

Shrubs are shown as irregular blobs with soft edges (search snippet: organic forms for planting beds, noise-perturbed outlines). Hedges are continuous bands with a darker outer edge. Bushes sit above the ground texture and under the building base (archez blog snippet).

### Buildings

- Light fill, crisp dark outline, optionally a roof accent in terracotta or red (Schlossgarten, Latrobe).
- Roof detail is shown only with a thin line at about 60% opacity (VA tutorial, line-work layer on Multiply).
- Hatched fill is used for historical plans (Baltard, Central Park), not for modern colour renders.

### Paving

- Flat ochre or sand fill with module joints drawn at low weight.
- Plazas: joint pattern shown only at the perimeter if the paving is secondary.
- Roads: darker than paving; cars and kerbs drawn as the most detailed edge.

### Water

- Blue-grey or blue watercolour wash with lighter edges (Baltard Seine).
- Modern renders: near-black pond with a soft edge (Hogrefe).
- Stream: a double line with a wash fill.

### Typography

- **Title**: spaced serif capitals (Baltard: "PLAN DU MARCHÉ PROVISOIRE AUX CHARBONS").
- **Labels**: small sans-serif or serif capitals, placed in the plan, not in a legend box. Hand-plans use cursive for names (Richmond "City of Richmond").
- **Compass**: a simple cross with N, E, S, W (Richmond, Schlossgarten).
- **Scale bar**: a segmented bar at the bottom (Schlossgarten, Baltard).
- **Dates**: handwritten or stamped on the sheet corner (Baltard sheet, date to verify).

## Reference examples

Local file column: `references/web/...` if downloaded. "Text only" means read from a snippet or page text, not downloaded.

| # | Title | Office / author | URL | Local file | Notes |
|---|---|---|---|---|---|
| 1 | Projet de marché aux charbons: site plan with landscape rendered | Louis-Pierre Baltard (d. 1846); sheet date handwritten, reads as 1817, to verify | https://commons.wikimedia.org/wiki/File:Louis-Pierre_Baltard_-_Projet_de_march%C3%A9_aux_charbons._Site_plan_with_landscape_rendered.jpg | `la-01-commons-baltard-site-plan-landscape-rendered.jpg` | Public domain. Wash-rendered site plan: sage lawns, clustered tree masses with dark dabs, sand paths, pale hangar, Seine in blue wash, scale bar, title in spaced capitals. Closest match to the palette we want. |
| 2 | Schlossgarten Wächtersbach, Gestaltungsplan | Bodenbender (date not confirmed) | https://commons.wikimedia.org/wiki/File:Schlossgarten_W%C3%A4chtersbach-Plan_Bodenbender.jpg | `la-15-commons-schlossgarten-waechtersbach-gestaltungsplan-bodenbender.jpg` | Public domain. The strongest tree-vocabulary reference: two-tone crowns, narrow conifers, shadow sides, sparse trees on lawn, pink-terracotta building, compass and scale bar. |
| 3 | House, Richmond, Virginia: site plan and landscaping | Benjamin Henry Latrobe (1764–1820) | https://commons.wikimedia.org/wiki/File:House,_Richmond,_Virginia._Site_plan_and_landscaping_LCCN2001698099.jpg | `la-04-commons-latrobe-richmond-site-plan-landscaping.jpg` | Public domain. Scalloped cloud-outline crowns in ochre wash, a pink building accent, cursive labels, compass rose. Best precedent for the scalloped canopy outline. |
| 4 | United States Capitol grounds: site plan, footprint, landscaping | Charles Bulfinch (1763–1844) | https://commons.wikimedia.org/wiki/File:United_States_Capitol_grounds,_Washington,_D.C._Site_plan,_footprint,_landscaping_LCCN2002712004.jpg | `la-03-commons-bulfinch-capitol-grounds-site-plan-landscaping.jpg` | Public domain. Line-based: building as outline, trees as small symbols in rows along the edges, paths as double lines. Shows how a plan without colour still reads as a landscape plan. |
| 5 | Map of Central Park (Vaux & Olmsted, 1868) | Calvert Vaux, Frederick Law Olmsted (Geographicus reprint) | https://commons.wikimedia.org/wiki/File:1868_Vaux_%5E_Olmsted_Map_of_Central_Park%2C_New_York_City_-_Geographicus_-_CentralPark-CentralPark-1869.jpg | `la-02-commons-vaux-olmsted-central-park-map-1868.jpg` | Public domain. Printed, coloured: stipple tree clusters, pale green meadows, cream background, tan paths. Good precedent for a printed (not painted) look. |
| 6 | Quick site plans (Photoshop tutorial) | Visualizing Architecture (site author not named on the page) | https://visualizingarchitecture.com/tutorial-quick-site-plans/ | removed (tutorial screenshots, not a style reference) | Step-by-step Photoshop workflow (see Production techniques). Source aerial, layer stack, Multiply line work, Levels on shadow, Smudge, Overlay colour. |
| 7 | Alex Hogrefe site plan (the project used in the tutorial) | Alex Hogrefe | Watermark only: alexhogrefe.com (page not found) | removed | Final render: saturated olive greens, dark tree masses, white building with dark roof and brown wall, contour lines. Shows the modern Photoshop look, which is saturated, not pastel. |
| 8 | Trees pack, five top-view PSDs (contour, monochrome, watercolour) | Archez International | https://archezinternational.com/?p=706 | none (images were not retrievable) | Paid ($5). Three textures per tree that can be layered or used alone. Useful for a symbol vocabulary study. |
| 9 | Archez blog: trees in architectural illustration | Archez International | https://archezinternational.com/?p=8345 | none (text only) | Text on depth layering, scale (8–20 m trees) and brush styles per presentation type. |
| 10 | New tutorial: draw grouped trees for large-scale masterplans | LandSpace Architecture | https://landspacearch.gumroad.com/p/new-tutorial-draw-grouped-trees-for-large-scale-masterplans | none (title only) | Paid. Grouped trees for masterplans, relevant to clustering crowns. Content not read. |
| 11 | Using Photoshop in post-production renderings, Part 4 | LandFX | https://landfx.com/videos/webinars/5705-using-photoshop-in-post-production-renderings-part-4 | none (video) | Covers palette, brush painting, translucent canopy masks, cool shadows. Snippet only. |
| 12 | Site plans in Photoshop (course) | Showit Better | https://showitbetter.teachable.com/courses/site-plans-in-photoshop/lectures/24589892 | none | Paid. Cast shadows, trees, grass/water/road textures, Google Earth base. Lesson page not read. |
| 13 | Rendered site plan (open textbook chapter) | eCampus Ontario, Studio Skills | https://ecampusontario.pressbooks.pub/studioskills/?p=197 | none (403 on fetch; search snippet only) | Magic wand, pattern fill, drop shadows, colour selection. |
| 14 | How to render a master plan in Photoshop in 2 hours | Muhammad Muhyuddin (WorldArchitecture, 2018) | https://worldarchitecture.org/architecture-projects/hpghv/how-to-render-master-plan-in-photoshop-in-just-2-hours-project-pages.html | none (text: video link https://youtu.be/HzVm1ZWqzZ0) | Video tutorial. Page has no steps. |
| 15 | Freiraumgestaltung Rathaus- und Marx-Engels-Forum, Berlin | Stephan Lenzen Landschaftsarchitekten (visualisation Matthias Grobe) | https://www.berlin.de/sen/bauen/wettbewerbe/2021/freiraumgestaltung-rathaus-und-marx-engels-forum/ | none | Competition page with Lageplan and perspective, German practice. Image not downloaded. |
| 16 | Pastor-Karwehl-Platz, Osnabrück (Schinkelrunde exhibition panels) | Schinkelrunde (office not confirmed) | https://entwickelt.osnabrueck.de/fileadmin/entwickelt/schinkel/Praesentationen_4-Schinkelrunde.pdf | none (PDF) | Lageplan at 1:200 with retention depression, permeable paving and lawn; a section. German practice; tree symbols not confirmed. |
| 17 | Illustrative Landscape Masterplan (council file) | Office not confirmed (search snippet linked a Fabrik drawing to a Berkshire project) | https://wokingham.moderngov.co.uk/documents/s57941/Enc%207%20-%20Illustrative%20Landscape%20Masterplan.pdf | none (PDF) | Colour illustrative masterplan with a legend: meadow grass, retained hedgerow, existing trees, proposed native buffer. Good for legend structure. Attribution from search snippet only. |
| 18 | Houston Botanic Garden (West 8) | West 8 | https://www.west8.com/projects/houston-botanic-gardens/ | none | Project page, photos only. No plan image found. |
| 19 | Projects index | Topotek 1 | https://www.topotek1.de/ | none | Project index; no plan drawings found on the page. Plan drawings probably sit on project pages, not fetched. |
| 20 | Town Branch Commons (SCAPE) and Landezine index | SCAPE; Landezine | https://landezine.com/town-branch-commons/ | none | Photos only. Landezine index is photo thumbnails. Shows that most studio pages do not expose plan drawings to scraping. |
| 21 | Grouped plan symbols, Queensland landscape masterplans | EDQ development assessment attachments | https://edqdad.dsdip.qld.gov.au/developmentAssessments/attachments/view/25791 | none | Legend separates feature trees, tall narrow trees, flowering trees; shaded footpaths noted. Which of two EDQ attachments this is was not confirmed. |
| 22 | Beyond Massing Models: Procedural Techniques for Better Master Plan Renders (2023) | Autodesk University | https://www.autodesk.com/autodesk-university/class/Beyond-Massing-Models-Procedural-Techniques-for-Better-Master-Plan-Renders-2023 | none | Class page; procedural master-plan renders in 3D. Content not read. |
| 23 | Drawing trees in the landscape (course brief) | Clemson University, LARC 8120 | https://www.clemson.edu/caac/sites/larc/mla-courses/year-1/fall-semester/04-larc-8120-drawing-and-representation-files/02-larc-8120_drawing-and-representation_trees-in-the-landscape_brief.pdf | none | Shadow projection is a grading criterion; trees drafted at proportional size. Good for shadow rules. |
| 24 | Drawing course (Frankfurt University of Applied Sciences) | Frankfurt University | https://campuas.frankfurt-university.de/mod/resource/view.php?id=213688 | none (PDF) | Line-weight hierarchy (thicker for trees than areas), 1:500 Lageplan as Dachaufsicht. Snippet only. |
| 25 | Tree symbols and canopy colour (CAD symbol packs) | CADTutor forum (2D tree symbols collections) | https://www.cadtutor.net/forum/files/file/1-2d-tree-symbols-collection-1/ | none | Per-canopy layers so colour changes independently. Useful for data-driven colouring. |

Also useful: the Berlin competition pages on berlin.de (Rathaus der Zukunft Preisträger, Blankenburger Süden) publish Lagepläne as downloads. Not fetched; a good next target for German-language examples.

### What did not work

- West 8 and Topotek 1 project pages expose photos, not plan drawings, to the fetch tool.
- Landezine and ArchDaily pages gave photo thumbnails. ArchDaily tree tips page had no tip text.
- lutzow7.de did not resolve. hager-partner.de, bbz-landschaftsarchitekten.de and levinmonsigny.com did not connect. atelier-loidl.de redirected (301) and was not followed.
- The Pressbooks chapter returned 403.
- No GROSS.MAX. or Atelier Loidl plan images were found through search.
- Pinterest was not used (not accessible through the tools here).
- Wikimedia Commons has many public-domain historical plans; most garden and site plans there are older than the modern style we want, and the Commons search for "rendered site plan" turned up nothing modern.

## Production techniques and tutorials

### Photoshop site-plan recipe (Visualizing Architecture, "Quick site plans")

URL: https://visualizingarchitecture.com/tutorial-quick-site-plans/ (steps verified from the page; step images were downloaded and later removed).

1. Base: highest-resolution aerial, preferred over a 3D model for texture.
2. Desaturate (Image > Adjustments > Desaturate).
3. Topography lines: invert a contour layer so the lines are white, set to Lighten to remove the white background.
4. SketchUp (or other 3D) export as three separate images: shaded colour, line work, and shadows. Confirm shadow direction matches the aerial.
5. Building colour layer: scale to site, erase background so only the building remains.
6. Line work: Multiply to remove white, reduce opacity so only roof detail shows.
7. Shadow layer: Levels, drag the black point until shadows are solid black.
8. Shadow layer: Multiply.
9. Smudge at 92% strength to soften edges away from the building. Soft eraser at 25% to fade outer edges. Darkest at the building.
10. Colour layer below the building: soft brush at 50% opacity radiating from the building.
11. Colour layer set to Overlay at 68% opacity.
12. Final output.

### Other tutorials and tools

- **Cutout trees with Multiply**: Visualizing Architecture, "Just playing around continued" (https://visualizingarchitecture.com/just-playing-around-continued/). Trees cut from a site photo, Multiply to remove white background, Dodge on grass to isolate tree and shadow detail.
- **Ambient occlusion from clay renders**: Visualizing Architecture (https://visualizingarchitecture.com/?p=866). A second clay render as AO layer to stop shadows looking flat.
- **Photoshop post-production, Part 4**: LandFX (https://landfx.com/videos/webinars/5705-using-photoshop-in-post-production-renderings-part-4). Palette, brush painting, translucent canopy masks, cool shadows.
- **Site plans in Photoshop**: Showit Better (https://showitbetter.teachable.com/courses/site-plans-in-photoshop/lectures/24589892). Paid. Shadows, trees, textures, Google Earth base.
- **Rendered site plan**: Studio Skills, eCampus Ontario (https://ecampusontario.pressbooks.pub/studioskills/?p=197). Magic wand, pattern fill, drop shadows.
- **Master plan render in 2 hours**: WorldArchitecture (https://worldarchitecture.org/architecture-projects/hpghv/how-to-render-master-plan-in-photoshop-in-just-2-hours-project-pages.html). Video: https://youtu.be/HzVm1ZWqzZ0.
- **Trees pack (PSD)**: Archez International (https://archezinternational.com/?p=706). Contour, monochrome and watercolour versions per species.
- **Grouped trees for masterplans**: LandSpace Architecture (https://landspacearch.gumroad.com/p/new-tutorial-draw-grouped-trees-for-large-scale-masterplans). Paid.
- **Illustrator**: no site-plan-specific tutorial found. Creative Bloq covers tree drawing in Illustrator (https://www.creativebloq.com/branding/creating-trees-illustrator-4089352), aimed at illustration rather than plans.
- **Landscape Architectural Graphic Standards** (Hopper, ed., Wiley): the reference book most often cited for plan conventions. A student edition exists; check for a newer edition.

## Procedural and GIS precedents

No source found that generates the full landscape-plan look from OSM or GIS data. These are partial precedents.

- **Processing SVG export**: https://bjango.com/articles/processingsvg/. Processing can write SVG directly, useful for vector output. Note: set styles after `beginRecord()`, or they do not reach the SVG.
- **Procedural tree canopy shapes**: no tutorial for cloud-outline canopies found. Suggested approach (own design, untested): canopy polygon = circle with noise-perturbed radius, or a union of jittered circles; fixed random seed per tree ID so the output is reproducible.
- **Mapbox Standard**: https://docs.mapbox.com/map-styles/reference/standard/. Classic styles are no longer maintained, per Mapbox; Standard has 3D buildings, dynamic lighting, and toggles for shadows, ambient occlusion and 3D trees. Useful for a 3D reference, not a plan look.
- **MapTiler Pastel**: https://www.maptiler.com/blog/2019/06/new-pastel-and-topographique-map-styles.html. Muted landcover greens, beige or pale-pink land uses, white roads. Closest pastel basemap found; not a plan look, but a palette reference.
- **Maputnik**: MapLibre style editor for building-fill and outline colours (the `fill-outline-color` property is from general knowledge, not checked against the spec in this session).
- **QGIS Polygon Oriented Hatch**: https://plugins.qgis.org/styles/59 (page returned for the query; not verified as the exact plugin). Hatches follow polygon orientation, shown only between 1:1 and 1:1000. Possible fit for building hatch in print layouts.
- **Shadow tools**: Shadow Map and ShadeMap (interactive, search snippet). Use to check real shadow direction and length for Neukölln at a given time, then reproduce in QGIS.
- **QGIS shadow method** (general knowledge, not tested): extrude building footprints by height, offset along sun azimuth, union, and render as a semi-transparent Multiply-like fill in a shadow layer.
- **CAD-Atlas**: https://cad-atlas.com/city/deir-al-balah-palestine/site-plan/ (commercial, editable vector site plans; not used).
- **OSM tags to consider for the pipeline** (general knowledge, to verify on our data): `natural=tree` with `diameter_crown` and `height` where available; `landuse=grass` / `meadow`; `surface` for paving; `building` with `roof:colour` and `roof:material`.

## Open questions

1. **Scale and legibility**: at z15–16 canopies are sub-pixel. Do we switch tree rendering by zoom, or use a fixed minimum crown size?
2. **Crown size source**: OSM trees often lack `diameter_crown`. Fallback by species or by `height` needs a rule.
3. **Shadow azimuth**: a fixed azimuth is simple, but real shadows depend on time of day. Pick a reference time (e.g. 15:00 in summer, a common plan convention) and document it in the style.
4. **Pastel versus saturated**: the historical references support muted tones; the modern tutorial output is saturated. Which one should Straßenraumkarte follow? Probably the historical palette, with the modern shadow recipe.
5. **Paper texture and hatching**: do we want them in the first pass? They add complexity to the QGIS style and print output.
6. **Labels**: keep OSM names in a sans-serif, or move to spaced serif capitals for the title block?
7. **Pipeline**: which parts can be SQL (footprints, shadow geometry, crown polygons) and which need QGIS (hatch, Overlay-style colour, labels)? Overlay and Multiply blending are available in QGIS layer styles; verify per version.
8. **Copyright**: the historical plans are public domain. The Visualizing Architecture and Hogrefe images are not; they are kept locally for reference and not committed.
9. **Missing modern references**: plan images from Topotek 1, West 8, Lützow 7, bbz, Hager and Atelier Loidl were not obtainable with these tools. A next step is direct contact with offices or a search for their published competition boards (berlin.de Preisträger pages look most promising).
