# Ink 11 — variant: oblique view for free-standing buildings

The open question of the exploration — *where pseudo-3D, where plan?* — as a switch:

```bash
SRK_INK_OBLIQUE=freestanding srk-render --layers ink …
```

- A building is **free-standing** when no other building (not counting `building:part`) lies within 0.8 m (SQL `NOT EXISTS … ST_DWithin`).
- Free-standing buildings and landmarks are **lifted**: the roof (with hatch, ridge, shaded half) moves north by a stylised height (½ of `height` / `building:levels`×3 m, clamped 3–18 m; landmarks 0.6×), the south walls are drawn from the footprint up to the roof with one row of windows per ~3 m. The footprint stays correct on the ground — the convention of bird's-eye city views.
- Rows and perimeter blocks stay in plan view, so dense streets never collide.
- From z17; painted north → south like everything upright.

**Look at:** `compare-c.jpg` (allotment huts at Hasenheide: plan left, oblique right) and `compare-a.jpg` (Genezarethkirche). `sheet.jpg` shows the four scenes with the variant on.

**Verdict (Claude):** this reads most like the "Step 8 – ink your village" reference wherever buildings stand alone (parks, allotments, schools, the church) and costs nothing in dense blocks. Candidate for the default.
