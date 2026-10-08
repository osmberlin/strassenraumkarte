"""One-off editor that added `*-layer-blur-mode` on top of apply-layer-blur.py.

Run from `vector/` after `bun patch` of both packages (with the layer-blur edits
already applied), then `bun patch --commit` both. Asserts on every anchor.
"""

def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    assert n == count, (path, old[:60], n)
    open(path, 'w').write(s.replace(old, new))

GL = 'node_modules/maplibre-gl/dist/'
SPEC = 'node_modules/@maplibre/maplibre-gl-style-spec/dist/'
T = '\t\t'
MODES = ['normal', 'inner-edge', 'inner-core']

def spec_entry(kind):
    values = ',\n'.join(f'{T}\t\t"{m}": {{}}' for m in MODES)
    return (f'{T}"{kind}-layer-blur-mode": {{\n{T}\t"type": "enum",\n{T}\t"values": {{\n{values}\n{T}\t}},\n'
            f'{T}\t"default": "normal",\n{T}\t"property-type": "data-constant"\n{T}}},\n')

for path in [GL + 'maplibre-gl-shared-dev.mjs', SPEC + 'index.mjs', SPEC + 'index.cjs']:
    for kind in ['fill', 'line']:
        anchor = f'{T}"{kind}-layer-opacity": {{\n'
        sub(path, anchor, spec_entry(kind) + anchor)

p = GL + 'maplibre-gl-shared-dev.mjs'
for kind in ['fill', 'line']:
    old = f'\t"{kind}-layer-blur": new DataConstantProperty(latest["paint_{kind}"]["{kind}-layer-blur"], "{kind}-layer-blur"),\n'
    sub(p, old, old + f'\t"{kind}-layer-blur-mode": new DataConstantProperty(latest["paint_{kind}"]["{kind}-layer-blur-mode"], "{kind}-layer-blur-mode"),\n')

p = GL + 'maplibre-gl-dev.mjs'
# shader: second sampler with the unblurred layer + mode switch
sub(p, 'uniform sampler2D u_image;uniform float u_opacity;uniform vec2 u_step;in vec2 v_pos;const int TAPS=16;',
       'uniform sampler2D u_image;uniform sampler2D u_source;uniform float u_opacity;uniform float u_mode;uniform vec2 u_step;in vec2 v_pos;const int TAPS=16;')
sub(p, 'fragColor=sum/total*u_opacity;',
       'vec4 blurred=sum/total;'
       'if (u_mode>1.5) {blurred=texture(u_source,v_pos)*clamp(2.0*blurred.a-1.0,0.0,1.0);}'
       'else if (u_mode>0.5) {blurred=texture(u_source,v_pos)*(1.0-blurred.a);}'
       'fragColor=blurred*u_opacity;')
sub(p, '''	"u_opacity": new Uniform1f(context, locations.u_opacity),
	"u_step": new Uniform2f(context, locations.u_step)
});
const layerBlurUniformValues = (opacity, textureUnit, step) => ({
	"u_image": textureUnit,
	"u_opacity": opacity,
	"u_step": step
});''', '''	"u_source": new Uniform1i(context, locations.u_source),
	"u_opacity": new Uniform1f(context, locations.u_opacity),
	"u_mode": new Uniform1f(context, locations.u_mode),
	"u_step": new Uniform2f(context, locations.u_step)
});
const layerBlurModes = {
	"normal": 0,
	"inner-edge": 1,
	"inner-core": 2
};
const layerBlurUniformValues = (opacity, textureUnit, step, mode) => ({
	"u_image": textureUnit,
	"u_source": 1,
	"u_opacity": opacity,
	"u_mode": mode,
	"u_step": step
});''')
sub(p, '''* into `layerBlurFbo`, vertical pass onto the composite target with opacity + blend mode.
*/
function drawLayerBlur(painter, opacity, blur, target, layer, colorMode) {''', '''* into `layerBlurFbo`, vertical pass onto the composite target with opacity + blend mode.
* `mode` combines the blurred alpha `b` with the unblurred layer `S` in the last pass:
*   inner-edge: S·(1 − b)   — strongest at the shape edge, gone ~radius inside (inner shadow/glow)
*   inner-core: S·(2b − 1)  — zero at the edge, full ~radius inside (shapeburst-like)
*/
function drawLayerBlur(painter, opacity, blur, target, layer, colorMode, mode) {''')
sub(p, 'layerBlurUniformValues(passOpacity, 0, [stepX, stepY])', 'layerBlurUniformValues(passOpacity, 0, [stepX, stepY], passMode)')
sub(p, 'const draw = (stepX, stepY, passOpacity, passColorMode) =>', 'const draw = (stepX, stepY, passOpacity, passColorMode, passMode) =>')
sub(p, '	draw(tapSpacing / width, 0, 1, ColorMode.unblended);\n', '	draw(tapSpacing / width, 0, 1, ColorMode.unblended, 0);\n')
sub(p, '''	gl.bindTexture(gl.TEXTURE_2D, painter.layerBlurFbo.colorAttachment.get());
	draw(0, tapSpacing / height, opacity, colorMode);
''', '''	context.activeTexture.set(gl.TEXTURE1);
	gl.bindTexture(gl.TEXTURE_2D, painter.layerOpacityFbo.colorAttachment.get());
	context.activeTexture.set(gl.TEXTURE0);
	gl.bindTexture(gl.TEXTURE_2D, painter.layerBlurFbo.colorAttachment.get());
	draw(0, tapSpacing / height, opacity, colorMode, layerBlurModes[mode] || 0);
''')
sub(p, 'function drawLayerOpacity(painter, opacity, prepareDrawLayerOpacityResult, layer, blend, blur) {', 'function drawLayerOpacity(painter, opacity, prepareDrawLayerOpacityResult, layer, blend, blur, blurMode) {')
sub(p, 'drawLayerBlur(painter, opacity, blur, prepareDrawLayerOpacityResult, layer, colorMode);', 'drawLayerBlur(painter, opacity, blur, prepareDrawLayerOpacityResult, layer, colorMode, blurMode);')
for kind in ['line', 'fill']:
    sub(p, f'\tconst layerBlur = layer.paint.get("{kind}-layer-blur");\n',
        f'\tconst layerBlur = layer.paint.get("{kind}-layer-blur");\n\tconst layerBlurMode = layer.paint.get("{kind}-layer-blur-mode");\n')
sub(p, 'drawLayerOpacity(painter, layerOpacity, results, layer, layerBlend, layerBlur);', 'drawLayerOpacity(painter, layerOpacity, results, layer, layerBlend, layerBlur, layerBlurMode);', count=2)

U = ' | '.join(f'"{m}"' for m in MODES)
p = GL + 'maplibre-gl.d.ts'
for kind in ['fill', 'line']:
    sub(p, f'  "{kind}-layer-blur": DataConstantProperty<number>;\n', f'  "{kind}-layer-blur": DataConstantProperty<number>;\n  "{kind}-layer-blur-mode": DataConstantProperty<{U}>;\n')
    sub(p, f'  "{kind}-layer-blur": number;\n', f'  "{kind}-layer-blur": number;\n  "{kind}-layer-blur-mode": {U};\n')
p = SPEC + 'index.d.ts'
for kind in ['fill', 'line']:
    for ind in ['    ', '  ']:
        old = f'\n{ind}"{kind}-layer-blur"?: PropertyValueSpecification<number>;\n'
        sub(p, old, old + f'{ind}/** [strassenraumkarte patch] How the blurred layer is combined with the unblurred one. */\n{ind}"{kind}-layer-blur-mode"?: {U};\n')
print('ok')
