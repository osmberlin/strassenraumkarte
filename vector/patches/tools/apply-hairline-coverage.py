"""One-off editor that added sub-pixel line ink correction to the maplibre-gl patch.

Run from `vector/` after `bun patch maplibre-gl@<v>`, then `bun patch --commit`.

MapLibre's line fragment shader gives a line of device width w < 1 px a triangular
alpha profile with peak (w/2 + 0.5) and the same half-width, i.e. (w/2 + 0.5)^2 px of
ink. That floor of ~0.25 px makes 0.05 px hairlines look crisp and far too strong.

Target, fitted to QGIS: ink(w) = w * (2 - w). Measured by projecting `building_lines`
into QGIS and MapLibre screenshots and integrating the darkening across each line
(scratch script, 2026-10-08): QGIS puts down ~1.9x / 2.0x / 1.4x the true coverage w at
z17 / z18 / z19 (w ~ 0.06-0.14 / 0.27 / 0.55 px). Plain coverage (ink = w) was visibly
too faint, MapLibre's own floor too strong at z17. w*(2-w) is 0 at w = 0, 1 at w = 1.
Skipped for blurred lines and lines with a gap width, whose profile is different.
"""
p = 'node_modules/maplibre-gl/dist/maplibre-gl-dev.mjs'
s = open(p).read()
old = 'float alpha=clamp(min(dist-(v_width2.t-blur2),v_width2.s-dist)/blur2,0.0,1.0);'
n = s.count(old)
assert n >= 2, n  # line, lineSDF (+ gradient / pattern variants)
new = (old + 'if (blur==0.0 && v_width2.t==0.0) {float hairline_o=v_width2.s*u_device_pixel_ratio;'
       'float hairline_w=max(2.0*hairline_o-1.0,0.0);'
       'if (hairline_w<1.0) {alpha=min(alpha*hairline_w*(2.0-hairline_w)/(hairline_o*hairline_o),1.0);}}')
open(p, 'w').write(s.replace(old, new))
print('patched', n, 'line programs')
