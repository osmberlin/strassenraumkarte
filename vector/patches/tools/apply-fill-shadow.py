"""One-off editor that added `fill-shadow-*` to the maplibre-gl patch.

Run from `vector/` after `bun patch` of both packages (with layer-blend, layer-blur,
layer-blur-mode already applied), then `bun patch --commit` both. Asserts on every anchor.

A fill layer with `fill-shadow-opacity` > 0 is rendered to the scratch FBO once; the FBO's
alpha is blurred, tinted with `fill-shadow-color`, shifted by `fill-shadow-translate`
(map-anchored CSS px) and multiplied onto the map, then the layer itself is composited
from the same FBO. One style layer instead of a shadow layer plus a source layer.
"""

def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    assert n == count, (path, old[:70], n)
    open(path, 'w').write(s.replace(old, new))

GL = 'node_modules/maplibre-gl/dist/'
SPEC = 'node_modules/@maplibre/maplibre-gl-style-spec/dist/'
T = '\t\t'
ZOOM = f'{T}\t"expression": {{\n{T}\t\t"interpolated": true,\n{T}\t\t"parameters": ["zoom", "global-state"]\n{T}\t}},\n{T}\t"property-type": "data-constant"\n{T}}},\n'
ENTRIES = (
    f'{T}"fill-shadow-color": {{\n{T}\t"type": "color",\n{T}\t"default": "#000000",\n' + ZOOM +
    f'{T}"fill-shadow-opacity": {{\n{T}\t"type": "number",\n{T}\t"default": 0,\n{T}\t"minimum": 0,\n{T}\t"maximum": 1,\n' + ZOOM +
    f'{T}"fill-shadow-blur": {{\n{T}\t"type": "number",\n{T}\t"default": 0,\n{T}\t"minimum": 0,\n{T}\t"units": "pixels",\n' + ZOOM +
    f'{T}"fill-shadow-translate": {{\n{T}\t"type": "array",\n{T}\t"value": "number",\n{T}\t"length": 2,\n{T}\t"default": [0, 0],\n{T}\t"units": "pixels",\n' + ZOOM
)
for path in [GL + 'maplibre-gl-shared-dev.mjs', SPEC + 'index.mjs', SPEC + 'index.cjs']:
    anchor = f'{T}"fill-layer-opacity": {{\n'
    sub(path, anchor, ENTRIES + anchor)

p = GL + 'maplibre-gl-shared-dev.mjs'
old = '\t"fill-layer-blur-mode": new DataConstantProperty(latest["paint_fill"]["fill-layer-blur-mode"], "fill-layer-blur-mode"),\n'
sub(p, old, old + ''.join(f'\t"fill-shadow-{k}": new DataConstantProperty(latest["paint_fill"]["fill-shadow-{k}"], "fill-shadow-{k}"),\n' for k in ['color', 'opacity', 'blur', 'translate']))

p = GL + 'maplibre-gl-dev.mjs'
# --- shader: tint + offset, shadow mode
sub(p, 'uniform sampler2D u_image;uniform sampler2D u_source;uniform float u_opacity;uniform float u_mode;uniform vec2 u_step;in vec2 v_pos;const int TAPS=16;',
       'uniform sampler2D u_image;uniform sampler2D u_source;uniform float u_opacity;uniform float u_mode;uniform vec2 u_step;uniform vec2 u_offset;uniform vec4 u_tint;in vec2 v_pos;const int TAPS=16;')
sub(p, 'void main() {vec4 sum=texture(u_image,v_pos);float total=1.0;', 'void main() {vec2 p=v_pos-u_offset;vec4 sum=texture(u_image,p);float total=1.0;')
sub(p, 'sum+=(texture(u_image,v_pos+o)+texture(u_image,v_pos-o))*w;', 'sum+=(texture(u_image,p+o)+texture(u_image,p-o))*w;')
sub(p, 'vec4 blurred=sum/total;if (u_mode>0.5) {', 'vec4 blurred=sum/total;if (u_mode>2.5) {blurred=u_tint*blurred.a;} else if (u_mode>0.5) {')
sub(p, '''	"u_mode": new Uniform1f(context, locations.u_mode),
	"u_step": new Uniform2f(context, locations.u_step)
});''', '''	"u_mode": new Uniform1f(context, locations.u_mode),
	"u_step": new Uniform2f(context, locations.u_step),
	"u_offset": new Uniform2f(context, locations.u_offset),
	"u_tint": new Uniform4f(context, locations.u_tint)
});''')
sub(p, '''	"inner-edge": 1,
	"inner-core": 2
};''', '''	"inner-edge": 1,
	"inner-core": 2,
	"shadow": 3
};''')
sub(p, '''const layerBlurUniformValues = (opacity, textureUnit, step, mode) => ({
	"u_image": textureUnit,
	"u_source": 1,
	"u_opacity": opacity,
	"u_mode": mode,
	"u_step": step
});''', '''const layerBlurUniformValues = (opacity, textureUnit, step, mode, offset, tint) => ({
	"u_image": textureUnit,
	"u_source": 1,
	"u_opacity": opacity,
	"u_mode": mode,
	"u_step": step,
	"u_offset": offset,
	"u_tint": tint
});''')
sub(p, 'function drawLayerBlur(painter, opacity, blur, target, layer, colorMode, mode) {', 'function drawLayerBlur(painter, opacity, blur, target, layer, colorMode, mode, offset = [0, 0], tint = [0, 0, 0, 0]) {')
sub(p, 'const draw = (stepX, stepY, passOpacity, passColorMode, passMode) =>', 'const draw = (stepX, stepY, passOpacity, passColorMode, passMode, passOffset = [0, 0]) =>')
sub(p, 'layerBlurUniformValues(passOpacity, 0, [stepX, stepY], passMode)', 'layerBlurUniformValues(passOpacity, 0, [stepX, stepY], passMode, passOffset, tint)')
sub(p, '	draw(0, tapSpacing / height, opacity, colorMode, layerBlurModes[mode] || 0);\n', '	draw(0, tapSpacing / height, opacity, colorMode, layerBlurModes[mode] || 0, offset);\n')

# --- shadow pass, called between rendering the layer and compositing it
sub(p, 'function drawLayerOpacity(painter, opacity, prepareDrawLayerOpacityResult, layer, blend, blur, blurMode) {', '''/**
* [strassenraumkarte patch] `fill-shadow-*`: drop shadow cast by the layer in the scratch FBO.
* Blurred alpha, tinted, shifted by `translate` (CSS px, map-anchored) and multiplied onto
* the composite target. The FBO is left untouched for the following drawLayerOpacity.
*/
function drawLayerShadow(painter, target, layer, color, opacity, blur, translate) {
	const { width, height } = painter.layerOpacityFbo;
	const angle = -painter.transform.bearingInRadians;
	const sinA = Math.sin(angle);
	const cosA = Math.cos(angle);
	const dx = (translate[0] * cosA - translate[1] * sinA) * painter.pixelRatio;
	const dy = (translate[0] * sinA + translate[1] * cosA) * painter.pixelRatio;
	const colorMode = painter._showOverdrawInspector ? painter.colorModeForRenderPass() : ColorMode.layerBlend.multiply;
	drawLayerBlur(painter, opacity, blur, target, layer, colorMode, "shadow", [dx / width, -dy / height], [
		color.r,
		color.g,
		color.b,
		color.a
	]);
}
function drawLayerOpacity(painter, opacity, prepareDrawLayerOpacityResult, layer, blend, blur, blurMode) {''')
sub(p, '''	const layerBlurMode = layer.paint.get("fill-layer-blur-mode");
	if (opacity.constantOr(1) === 0 || layerOpacity === 0) return;
	if (layerOpacity < 1 || layerBlend !== "normal" || layerBlur > 0) {''', '''	const layerBlurMode = layer.paint.get("fill-layer-blur-mode");
	const shadowOpacity = layer.paint.get("fill-shadow-opacity");
	if (opacity.constantOr(1) === 0 || layerOpacity === 0) return;
	if (layerOpacity < 1 || layerBlend !== "normal" || layerBlur > 0 || shadowOpacity > 0) {''')
sub(p, '''		drawFillAndOutline(painter, tileManager, layer, coords, renderOptions);
		drawLayerOpacity(painter, layerOpacity, results, layer, layerBlend, layerBlur, layerBlurMode);''', '''		drawFillAndOutline(painter, tileManager, layer, coords, renderOptions);
		if (shadowOpacity > 0) drawLayerShadow(painter, results, layer, layer.paint.get("fill-shadow-color"), shadowOpacity, layer.paint.get("fill-shadow-blur"), layer.paint.get("fill-shadow-translate"));
		drawLayerOpacity(painter, layerOpacity, results, layer, layerBlend, layerBlur, layerBlurMode);''')

# --- types
p = GL + 'maplibre-gl.d.ts'
sub(p, '  "fill-layer-blur": DataConstantProperty<number>;\n', '  "fill-layer-blur": DataConstantProperty<number>;\n  "fill-shadow-color": DataConstantProperty<Color>;\n  "fill-shadow-opacity": DataConstantProperty<number>;\n  "fill-shadow-blur": DataConstantProperty<number>;\n  "fill-shadow-translate": DataConstantProperty<[number, number]>;\n')
sub(p, '  "fill-layer-blur": number;\n', '  "fill-layer-blur": number;\n  "fill-shadow-color": Color;\n  "fill-shadow-opacity": number;\n  "fill-shadow-blur": number;\n  "fill-shadow-translate": [number, number];\n')
p = SPEC + 'index.d.ts'
for ind in ['    ', '  ']:
    old = f'\n{ind}"fill-layer-blur"?: PropertyValueSpecification<number>;\n'
    sub(p, old, old + (f'{ind}/** [strassenraumkarte patch] Drop shadow cast by the layer: colour, opacity (0 = off), blur radius and map-anchored offset in px; multiplied onto the map. */\n'
                       f'{ind}"fill-shadow-color"?: PropertyValueSpecification<ColorSpecification>;\n'
                       f'{ind}"fill-shadow-opacity"?: PropertyValueSpecification<number>;\n'
                       f'{ind}"fill-shadow-blur"?: PropertyValueSpecification<number>;\n'
                       f'{ind}"fill-shadow-translate"?: PropertyValueSpecification<[number, number]>;\n'))
print('ok')
