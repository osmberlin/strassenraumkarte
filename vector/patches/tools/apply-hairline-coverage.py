"""One-off editor that added sub-pixel line coverage correction to the maplibre-gl patch.

Run from `vector/` after `bun patch maplibre-gl@<v>`, then `bun patch --commit`.

MapLibre's line fragment shader gives a line of device width w < 1 px a triangular
alpha profile with peak (w/2 + 0.5) and the same half-width, i.e. (w/2 + 0.5)^2 px of
ink instead of w. A 0.1 px hairline therefore renders three times too strong (QGIS /
any coverage-based rasteriser: 0.1). Scale alpha by w / (w/2 + 0.5)^2 below 1 px.
Skipped for blurred lines and lines with a gap width, whose profile is different.
"""
p = 'node_modules/maplibre-gl/dist/maplibre-gl-dev.mjs'
s = open(p).read()
old = 'float alpha=clamp(min(dist-(v_width2.t-blur2),v_width2.s-dist)/blur2,0.0,1.0);'
n = s.count(old)
assert n >= 2, n  # line, lineSDF (+ gradient / pattern variants)
new = (old + 'if (blur==0.0 && v_width2.t==0.0) {float hairline_o=v_width2.s*u_device_pixel_ratio;'
       'float hairline_w=max(2.0*hairline_o-1.0,0.0);'
       'if (hairline_w<1.0) {alpha*=hairline_w/(hairline_o*hairline_o);}}')
open(p, 'w').write(s.replace(old, new))
print('patched', n, 'line programs')
