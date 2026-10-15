# Test scenes

Four scenes from today's rendering (tiles from 2026-08-01, z19, 4×4 tiles = 1024×1024 px ≈ 190 m). They cover the situations both explorations must handle. Tile ranges are defined in [`../tools/make_scenes.py`](../tools/make_scenes.py).

| Scene | z19 tiles x / y | Why |
|---|---|---|
| ![](a-herrfurthplatz.jpg) **A — Herrfurthplatz** | 281689–281692 / 172043–172046 | Round square with a church (landmark), street trees, perimeter blocks |
| ![](b-schillerpromenade.jpg) **B — Schillerpromenade** | 281691–281694 / 172049–172052 | Promenade with playgrounds (accent test), tree rows, courtyard blocks |
| ![](c-hasenheide-edge.jpg) **C — Hasenheide edge** | 281682–281685 / 172039–172042 | Solitary trees vs woodland mass, pond, small houses |
| ![](d-courtyard-blocks.jpg) **D — Courtyard blocks** | 281701–281704 / 172044–172047 | Green courtyards with path figures, pedestrian street with playground |

Added in the night run (no QGIS rendering exists for them; DB bbox extended to `13.4102,52.4680,13.4520,52.4832`):

| Scene | z19 tiles x / y | Why |
|---|---|---|
| **E — Richardplatz** (Böhmisches Dorf, Rixdorf) | 281722–281725 / 172051–172054 | Village core with free-standing houses, smithy, church — test for the oblique variant |
| **F — Körnerpark** | 281712–281715 / 172058–172061 | Formal sunken garden with parterres, fountains and an orangery — test for the landscape-architecture style |
