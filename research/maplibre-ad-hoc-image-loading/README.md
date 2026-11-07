# MapLibre ad hoc image loading

Research notes on registering icons and patterns **at runtime** in MapLibre GL JS — when the style sprite is not enough, and how FMC projects (TILDA / VZK) already solve this.

## Contents

| File | Purpose |
| --- | --- |
| [summary.md](./summary.md) | Problem → strategies → APIs → pitfalls → recommendation |
| [sources.md](./sources.md) | Bibliography: MapLibre docs, FMC plans/code, related issues |

## Scope

Focus is **runtime** image registration (`addImage`, `loadImage`, missing-image hooks) for symbol/`*-pattern` layers — not building or merging sprite sheets at style-compile time (that path is covered briefly as the alternative when the icon set is closed and known).
