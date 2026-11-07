"""One-off editor that added `symbol-layer-opacity` to the maplibre-gl patch.

Run from `vector/` after `bun patch` of both packages (with the earlier layer-blend /
layer-blur edits applied), then `bun patch --commit` both. Asserts on every anchor.
"""
import re

def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    assert n == count, (path, old[:60], n)
    open(path, 'w').write(s.replace(old, new))

GL = 'node_modules/maplibre-gl/dist/'
SPEC = 'node_modules/@maplibre/maplibre-gl-style-spec/dist/'

# --- spec JSON: first property of paint_symbol, whatever the indentation
for path in [GL + 'maplibre-gl-shared-dev.mjs', SPEC + 'index.mjs', SPEC + 'index.cjs']:
    s = open(path).read()
    m = list(re.finditer(r'\n(\s*)"?paint_symbol"?: \{\n(\s*)"icon-opacity": \{\n', s))
    assert len(m) == 1, (path, len(m))
    t = m[0].group(2)
    entry = (f'{t}"symbol-layer-opacity": {{\n{t}\t"type": "number",\n{t}\t"default": 1,\n{t}\t"minimum": 0,\n{t}\t"maximum": 1,\n'
             f'{t}\t"expression": {{\n{t}\t\t"interpolated": true,\n{t}\t\t"parameters": ["zoom", "global-state"]\n{t}\t}},\n'
             f'{t}\t"property-type": "data-constant"\n{t}}},\n')
    i = m[0].end() - len(f'{t}"icon-opacity": {{\n')
    open(path, 'w').write(s[:i] + entry + s[i:])

p = GL + 'maplibre-gl-shared-dev.mjs'
old = '\t"icon-opacity": new DataDrivenProperty(latest["paint_symbol"]["icon-opacity"], "icon-opacity"),\n'
sub(p, old, '\t"symbol-layer-opacity": new DataConstantProperty(latest["paint_symbol"]["symbol-layer-opacity"], "symbol-layer-opacity"),\n' + old)

# --- renderer: flatten icons + text of the layer, then composite once
p = GL + 'maplibre-gl-dev.mjs'
sub(p, '''function drawSymbols(painter, tileManager, layer, coords, variableOffsets, renderOptions) {
	if (painter.renderPass !== "translucent") return;
''', '''function drawSymbols(painter, tileManager, layer, coords, variableOffsets, renderOptions) {
	if (painter.renderPass !== "translucent") return;
	// [strassenraumkarte patch] `symbol-layer-opacity`: draw the layer opaque into the
	// scratch FBO and composite it once, so overlapping symbols do not add up.
	const layerOpacity = layer.paint.get("symbol-layer-opacity");
	if (layerOpacity === 0) return;
	if (layerOpacity < 1 && !renderOptions.symbolLayerOpacityPass) {
		if (!coords.some((coord) => tileManager.getTile(coord).getBucket(layer))) return;
		const results = prepareDrawLayerOpacity(painter, layer, coords, !!painter.style.map.terrain);
		drawSymbols(painter, tileManager, layer, coords, variableOffsets, {
			...renderOptions,
			symbolLayerOpacityPass: true
		});
		drawLayerOpacity(painter, layerOpacity, results, layer, "normal", 0, "normal");
		return;
	}
''')

p = GL + 'maplibre-gl.d.ts'
sub(p, '  "icon-opacity": DataDrivenProperty<number>;\n', '  "symbol-layer-opacity": DataConstantProperty<number>;\n  "icon-opacity": DataDrivenProperty<number>;\n')
sub(p, '  "icon-opacity": PossiblyEvaluatedPropertyValue<number>;\n', '  "symbol-layer-opacity": number;\n  "icon-opacity": PossiblyEvaluatedPropertyValue<number>;\n')
p = SPEC + 'index.d.ts'
for ind in ['    ', '  ']:
    old = f'\n{ind}"icon-opacity"?: DataDrivenPropertyValueSpecification<number>;\n'
    sub(p, old, f'\n{ind}/** [strassenraumkarte patch] Opacity applied once to the flattened symbol layer. */\n{ind}"symbol-layer-opacity"?: PropertyValueSpecification<number>;' + old)
print('ok')
