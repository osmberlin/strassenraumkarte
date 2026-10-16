"""One-off editor that added ground-anchored, rotatable fill patterns to the maplibre-gl patch.

Run from `vector/` after `bun patch` of both packages (earlier edits applied), then
`bun patch --commit` both. Asserts on every anchor.

`fill-pattern-reference-zoom` (number, -1 = off): the pattern image keeps the ground size it
has at that zoom, i.e. its pixel size is multiplied by 2^(tileZoom - reference) and the
integer-zoom crossfade is bypassed. Still anchored to the global pixel grid, so it is
seamless across tiles and zoom levels.

`fill-pattern-rotate` (degrees clockwise, data-driven): rotates the pattern per feature.
Only in ground mode. The pivot is the tile origin: a rotated pattern lattice cannot be
reduced modulo the pattern size per axis, and float32 cannot carry the global pixel
coordinate through a rotation — so a rotated feature shows a phase seam at tile edges.
"""

def sub(path, old, new, count=1):
    s = open(path).read()
    n = s.count(old)
    assert n == count, (path, old[:70], n)
    open(path, 'w').write(s.replace(old, new))

GL = 'node_modules/maplibre-gl/dist/'
SPEC = 'node_modules/@maplibre/maplibre-gl-style-spec/dist/'
T = '\t\t'
ENTRIES = (
    f'{T}"fill-pattern-rotate": {{\n{T}\t"type": "number",\n{T}\t"default": 0,\n{T}\t"units": "degrees",\n'
    f'{T}\t"expression": {{\n{T}\t\t"interpolated": true,\n{T}\t\t"parameters": ["zoom", "feature"]\n{T}\t}},\n{T}\t"property-type": "data-driven"\n{T}}},\n'
    f'{T}"fill-pattern-reference-zoom": {{\n{T}\t"type": "number",\n{T}\t"default": -1,\n'
    f'{T}\t"expression": {{\n{T}\t\t"interpolated": true,\n{T}\t\t"parameters": ["zoom", "global-state"]\n{T}\t}},\n{T}\t"property-type": "data-constant"\n{T}}},\n'
)
for path in [GL + 'maplibre-gl-shared-dev.mjs', SPEC + 'index.mjs', SPEC + 'index.cjs']:
    anchor = f'{T}"fill-layer-opacity": {{\n'
    sub(path, anchor, ENTRIES + anchor)

p = GL + 'maplibre-gl-shared-dev.mjs'
old = '\t"fill-layer-blur-mode": new DataConstantProperty(latest["paint_fill"]["fill-layer-blur-mode"], "fill-layer-blur-mode"),\n'
sub(p, old, old + '\t"fill-pattern-rotate": new DataDrivenProperty(latest["paint_fill"]["fill-pattern-rotate"], "fill-pattern-rotate"),\n'
                  '\t"fill-pattern-reference-zoom": new DataConstantProperty(latest["paint_fill"]["fill-pattern-reference-zoom"], "fill-pattern-reference-zoom"),\n')

p = GL + 'maplibre-gl-dev.mjs'
# --- vertex shaders: fillPattern (tileZoomRatio) and fillOutlinePattern (tileRatio)
GROUND = ('if (u_pattern_ground > 0.0) {{vec2 ground_size=u_pattern_ground*display_size_a;'
          'if (pattern_rotate != 0.0) {{float ground_r=radians(pattern_rotate);float ground_c=cos(ground_r);float ground_s=sin(ground_r);'
          'vec2 ground_p={ratio}*a_pos;v_pos_a=vec2(ground_c*ground_p.x+ground_s*ground_p.y,-ground_s*ground_p.x+ground_c*ground_p.y)/ground_size;}} '
          'else {{v_pos_a=get_pattern_pos(u_pixel_coord_upper,u_pixel_coord_lower,ground_size,{ratio},a_pos);}}v_pos_b=v_pos_a;}}')
for ratio in ['tileZoomRatio', 'tileRatio']:
    old = (f'v_pos_a=get_pattern_pos(u_pixel_coord_upper,u_pixel_coord_lower,fromScale*display_size_a,{ratio},a_pos);'
           f'v_pos_b=get_pattern_pos(u_pixel_coord_upper,u_pixel_coord_lower,toScale*display_size_b,{ratio},a_pos);')
    sub(p, old, old + GROUND.format(ratio=ratio))
# declarations + pragma (both vertex shaders start their pragma list the same way)
old = ('uniform vec3 u_scale;uniform vec2 u_fill_translate;layout(location=0) in vec2 a_pos;out vec2 v_pos_a;out vec2 v_pos_b;')
sub(p, old, 'uniform vec3 u_scale;uniform float u_pattern_ground;uniform vec2 u_fill_translate;layout(location=0) in vec2 a_pos;out vec2 v_pos_a;out vec2 v_pos_b;', count=2)
old = '#pragma maplibre: define lowp float pixel_ratio_to\\nvoid main() {\\n#pragma maplibre: initialize lowp float opacity\\n#pragma maplibre: initialize mediump vec4 pattern_from\\n#pragma maplibre: initialize mediump vec4 pattern_to\\n#pragma maplibre: initialize lowp float pixel_ratio_from\\n#pragma maplibre: initialize lowp float pixel_ratio_to\\nif (opacity < 0.01) {gl_Position=vec4(-2.0,-2.0,-2.0,1.0);return;}vec2 pattern_tl_a=pattern_from.xy;vec2 pattern_br_a=pattern_from.zw;vec2 pattern_tl_b=pattern_to.xy;vec2 pattern_br_b=pattern_to.zw;float tile'
new = '#pragma maplibre: define lowp float pixel_ratio_to\\n#pragma maplibre: define mediump float pattern_rotate\\nvoid main() {\\n#pragma maplibre: initialize lowp float opacity\\n#pragma maplibre: initialize mediump vec4 pattern_from\\n#pragma maplibre: initialize mediump vec4 pattern_to\\n#pragma maplibre: initialize lowp float pixel_ratio_from\\n#pragma maplibre: initialize lowp float pixel_ratio_to\\n#pragma maplibre: initialize mediump float pattern_rotate\\nif (opacity < 0.01) {gl_Position=vec4(-2.0,-2.0,-2.0,1.0);return;}vec2 pattern_tl_a=pattern_from.xy;vec2 pattern_br_a=pattern_from.zw;vec2 pattern_tl_b=pattern_to.xy;vec2 pattern_br_b=pattern_to.zw;float tile'
sub(p, old, new, count=2)

# --- uniforms
sub(p, '''	"u_scale": new Uniform3f(context, locations.u_scale),
	"u_fade": new Uniform1f(context, locations.u_fade),
	"u_fill_translate": new Uniform2f(context, locations.u_fill_translate)
});''', '''	"u_scale": new Uniform3f(context, locations.u_scale),
	"u_fade": new Uniform1f(context, locations.u_fade),
	"u_pattern_ground": new Uniform1f(context, locations.u_pattern_ground),
	"u_fill_translate": new Uniform2f(context, locations.u_fill_translate)
});''', count=2)
sub(p, 'const fillPatternUniformValues = (painter, crossfade, tile, translate) => extend(patternUniformValues(crossfade, painter, tile), { "u_fill_translate": translate });',
       '''/**
* [strassenraumkarte patch] `fill-pattern-reference-zoom`: factor that keeps the pattern at the
* ground size it has at the reference zoom (0 = standard pixel-sized pattern).
*/
const patternGroundScale = (painter, layer) => {
	const referenceZoom = layer ? layer.paint.get("fill-pattern-reference-zoom") : -1;
	return referenceZoom >= 0 ? Math.pow(2, painter.transform.tileZoom - referenceZoom) : 0;
};
const fillPatternUniformValues = (painter, crossfade, tile, translate, layer) => extend(patternUniformValues(crossfade, painter, tile), {
	"u_fill_translate": translate,
	"u_pattern_ground": patternGroundScale(painter, layer)
});''')
sub(p, 'const fillOutlinePatternUniformValues = (painter, crossfade, tile, drawingBufferSize, translate) => extend(fillPatternUniformValues(painter, crossfade, tile, translate), { "u_world": drawingBufferSize });',
       'const fillOutlinePatternUniformValues = (painter, crossfade, tile, drawingBufferSize, translate, layer) => extend(fillPatternUniformValues(painter, crossfade, tile, translate, layer), { "u_world": drawingBufferSize });')
sub(p, 'uniformValues = image ? fillPatternUniformValues(painter, crossfade, tile, translateForUniforms) : fillUniformValues(translateForUniforms);',
       'uniformValues = image ? fillPatternUniformValues(painter, crossfade, tile, translateForUniforms, layer) : fillUniformValues(translateForUniforms);')
sub(p, 'fillOutlinePatternUniformValues(painter, crossfade, tile, drawingBufferSize, translateForUniforms)', 'fillOutlinePatternUniformValues(painter, crossfade, tile, drawingBufferSize, translateForUniforms, layer)')

# --- types
p = GL + 'maplibre-gl.d.ts'
sub(p, '  "fill-layer-blur": DataConstantProperty<number>;\n', '  "fill-layer-blur": DataConstantProperty<number>;\n  "fill-pattern-rotate": DataDrivenProperty<number>;\n  "fill-pattern-reference-zoom": DataConstantProperty<number>;\n')
sub(p, '  "fill-layer-blur": number;\n', '  "fill-layer-blur": number;\n  "fill-pattern-rotate": PossiblyEvaluatedPropertyValue<number>;\n  "fill-pattern-reference-zoom": number;\n')
p = SPEC + 'index.d.ts'
for ind in ['    ', '  ']:
    old = f'\n{ind}"fill-layer-blur"?: PropertyValueSpecification<number>;\n'
    sub(p, old, old + (f'{ind}/** [strassenraumkarte patch] Keep `fill-pattern` at the ground size it has at this zoom (-1 = pixel-sized). */\n'
                       f'{ind}"fill-pattern-reference-zoom"?: PropertyValueSpecification<number>;\n'
                       f'{ind}/** [strassenraumkarte patch] Rotate `fill-pattern` clockwise, degrees; needs `fill-pattern-reference-zoom`. */\n'
                       f'{ind}"fill-pattern-rotate"?: DataDrivenPropertyValueSpecification<number>;\n'))
print('ok')
