"""One-off editor used to create the `*-layer-blur` part of the maplibre-gl patch.

Kept for reference when re-applying the patch to a newer maplibre-gl: run it from
`vector/` after `bun patch maplibre-gl@<v>` and `bun patch @maplibre/maplibre-gl-style-spec@<v>`,
then `bun patch --commit` both. It asserts on every anchor, so a changed upstream fails loudly.
"""

def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    assert n == count, (path, old[:60], n)
    open(path, 'w').write(s.replace(old, new))

GL = 'node_modules/maplibre-gl/dist/'
SPEC = 'node_modules/@maplibre/maplibre-gl-style-spec/dist/'
T = '\t\t'

def spec_entry(kind):
    return (f'{T}"{kind}-layer-blur": {{\n{T}\t"type": "number",\n{T}\t"default": 0,\n{T}\t"minimum": 0,\n'
            f'{T}\t"units": "pixels",\n{T}\t"expression": {{\n{T}\t\t"interpolated": true,\n'
            f'{T}\t\t"parameters": ["zoom", "global-state"]\n{T}\t}},\n{T}\t"property-type": "data-constant"\n{T}}},\n')

# --- spec JSON
for path in [GL + 'maplibre-gl-shared-dev.mjs', SPEC + 'index.mjs', SPEC + 'index.cjs']:
    for kind in ['fill', 'line']:
        anchor = f'{T}"{kind}-layer-opacity": {{\n'
        sub(path, anchor, spec_entry(kind) + anchor)

# --- paint properties
p = GL + 'maplibre-gl-shared-dev.mjs'
for kind in ['fill', 'line']:
    old = f'\t"{kind}-layer-blend": new DataConstantProperty(latest["paint_{kind}"]["{kind}-layer-blend"], "{kind}-layer-blend"),\n'
    sub(p, old, old + f'\t"{kind}-layer-blur": new DataConstantProperty(latest["paint_{kind}"]["{kind}-layer-blur"], "{kind}-layer-blur"),\n')

# --- renderer
p = GL + 'maplibre-gl-dev.mjs'
VERT = 'layout(location=0) in vec2 a_pos;out vec2 v_pos;void main() {gl_Position=vec4(a_pos.x*2.0-1.0,1.0-a_pos.y*2.0,0.0,1.0);v_pos.x=a_pos.x;v_pos.y=1.0-a_pos.y;}'
FRAG = ('uniform sampler2D u_image;uniform float u_opacity;uniform vec2 u_step;in vec2 v_pos;'
        'const int TAPS=16;'
        'void main() {vec4 sum=texture(u_image,v_pos);float total=1.0;'
        'for (int i=1;i<=TAPS;i++) {float x=3.0*float(i)/float(TAPS);float w=exp(-0.5*x*x);vec2 o=u_step*float(i);'
        'sum+=(texture(u_image,v_pos+o)+texture(u_image,v_pos-o))*w;total+=2.0*w;}'
        'fragColor=sum/total*u_opacity;\\n#ifdef OVERDRAW_INSPECTOR\\nfragColor=vec4(0.0);\\n#endif\\n}')
sub(p, '\tlayerOpacity: prepare(', f'\tlayerBlur: prepare("{FRAG}", "{VERT}"),\n\tlayerOpacity: prepare(')
sub(p, '//#endregion\n//#region src/webgl/program/raster_program.ts', '''/**
* [strassenraumkarte patch] `{fill,line}-layer-blur`: one direction of a separable
* Gaussian over the layer scratch FBO. `u_step` is the tap spacing in UV units.
*/
const layerBlurUniforms = (context, locations) => ({
	"u_image": new Uniform1i(context, locations.u_image),
	"u_opacity": new Uniform1f(context, locations.u_opacity),
	"u_step": new Uniform2f(context, locations.u_step)
});
const layerBlurUniformValues = (opacity, textureUnit, step) => ({
	"u_image": textureUnit,
	"u_opacity": opacity,
	"u_step": step
});
//#endregion
//#region src/webgl/program/raster_program.ts''')
sub(p, '\tlayerOpacity: layerOpacityUniforms,\n', '\tlayerBlur: layerBlurUniforms,\n\tlayerOpacity: layerOpacityUniforms,\n')

sub(p, '''function drawLayerOpacity(painter, opacity, prepareDrawLayerOpacityResult, layer, blend) {
	const context = painter.context;
	const gl = context.gl;
	context.bindFramebuffer.set(prepareDrawLayerOpacityResult.compositeTarget);
	context.viewport.set(prepareDrawLayerOpacityResult.compositeViewport);
	context.activeTexture.set(gl.TEXTURE0);
	gl.bindTexture(gl.TEXTURE_2D, painter.layerOpacityFbo.colorAttachment.get());
	const colorMode = !painter._showOverdrawInspector && ColorMode.layerBlend[blend] || painter.colorModeForRenderPass();
''', '''/**
* [strassenraumkarte patch] Colour-only scratch FBO for the horizontal blur pass.
*/
function bindLayerBlur(painter, width, height) {
	const gl = painter.context.gl;
	let fbo = painter.layerBlurFbo;
	if (fbo && (fbo.width !== width || fbo.height !== height)) {
		fbo.destroy();
		fbo = null;
	}
	if (!fbo) {
		fbo = painter.context.createFramebuffer(width, height, false, false);
		const texture = gl.createTexture();
		gl.bindTexture(gl.TEXTURE_2D, texture);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
		fbo.colorAttachment.set(texture);
		painter.layerBlurFbo = fbo;
	}
	painter.context.bindFramebuffer.set(fbo.framebuffer);
}
/**
* [strassenraumkarte patch] Composite the layer scratch FBO with a Gaussian blur of
* `blur` CSS px (QGIS blur radius; σ = radius / 2, kernel cut at 3σ): horizontal pass
* into `layerBlurFbo`, vertical pass onto the composite target with opacity + blend mode.
*/
function drawLayerBlur(painter, opacity, blur, target, layer, colorMode) {
	const context = painter.context;
	const gl = context.gl;
	const { width, height } = painter.layerOpacityFbo;
	const tapSpacing = 3 * (blur * painter.pixelRatio / 2) / 16;
	const draw = (stepX, stepY, passOpacity, passColorMode) => painter.useProgram("layerBlur").draw(context, gl.TRIANGLES, DepthMode.disabled, StencilMode.disabled, passColorMode, CullFaceMode.disabled, layerBlurUniformValues(passOpacity, 0, [stepX, stepY]), null, null, layer.id, painter.viewportBuffer, painter.quadTriangleIndexBuffer, painter.viewportSegments, layer.paint, painter.transform.zoom);
	bindLayerBlur(painter, width, height);
	context.viewport.set([
		0,
		0,
		width,
		height
	]);
	context.clear({ color: Color.transparent });
	context.activeTexture.set(gl.TEXTURE0);
	gl.bindTexture(gl.TEXTURE_2D, painter.layerOpacityFbo.colorAttachment.get());
	draw(tapSpacing / width, 0, 1, ColorMode.unblended);
	context.bindFramebuffer.set(target.compositeTarget);
	context.viewport.set(target.compositeViewport);
	gl.bindTexture(gl.TEXTURE_2D, painter.layerBlurFbo.colorAttachment.get());
	draw(0, tapSpacing / height, opacity, colorMode);
	painter.currentStencilSource = void 0;
}
function drawLayerOpacity(painter, opacity, prepareDrawLayerOpacityResult, layer, blend, blur) {
	const context = painter.context;
	const gl = context.gl;
	const colorMode = !painter._showOverdrawInspector && ColorMode.layerBlend[blend] || painter.colorModeForRenderPass();
	if (blur > 0) {
		drawLayerBlur(painter, opacity, blur, prepareDrawLayerOpacityResult, layer, colorMode);
		return;
	}
	context.bindFramebuffer.set(prepareDrawLayerOpacityResult.compositeTarget);
	context.viewport.set(prepareDrawLayerOpacityResult.compositeViewport);
	context.activeTexture.set(gl.TEXTURE0);
	gl.bindTexture(gl.TEXTURE_2D, painter.layerOpacityFbo.colorAttachment.get());
''')
for kind in ['line', 'fill']:
    sub(p, f'\tconst layerBlend = layer.paint.get("{kind}-layer-blend");\n',
        f'\tconst layerBlend = layer.paint.get("{kind}-layer-blend");\n\tconst layerBlur = layer.paint.get("{kind}-layer-blur");\n')
sub(p, 'if (layerOpacity < 1 || layerBlend !== "normal") {', 'if (layerOpacity < 1 || layerBlend !== "normal" || layerBlur > 0) {', count=2)
sub(p, 'drawLayerOpacity(painter, layerOpacity, results, layer, layerBlend);', 'drawLayerOpacity(painter, layerOpacity, results, layer, layerBlend, layerBlur);', count=2)
sub(p, '\t\tthis.layerOpacityFbo?.destroy();\n\t\tthis.layerOpacityFbo = null;\n', '\t\tthis.layerOpacityFbo?.destroy();\n\t\tthis.layerOpacityFbo = null;\n\t\tthis.layerBlurFbo?.destroy();\n\t\tthis.layerBlurFbo = null;\n')

# --- types
p = GL + 'maplibre-gl.d.ts'
for kind in ['fill', 'line']:
    sub(p, f'  "{kind}-layer-opacity": DataConstantProperty<number>;\n', f'  "{kind}-layer-opacity": DataConstantProperty<number>;\n  "{kind}-layer-blur": DataConstantProperty<number>;\n')
    sub(p, f'  "{kind}-layer-opacity": number;\n', f'  "{kind}-layer-opacity": number;\n  "{kind}-layer-blur": number;\n')
p = SPEC + 'index.d.ts'
for kind in ['fill', 'line']:
    for ind in ['    ', '  ']:
        old = f'\n{ind}"{kind}-layer-opacity"?: PropertyValueSpecification<number>;\n'
        sub(p, old, old + f'{ind}/** [strassenraumkarte patch] Gaussian blur radius (px) applied to the whole layer. */\n{ind}"{kind}-layer-blur"?: PropertyValueSpecification<number>;\n')
print('ok')
