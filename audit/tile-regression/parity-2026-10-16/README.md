# Rust ↔ QGIS parity, 2026-10-16

Four parallel passes on `srk-render --layers full-approx` against the full QGIS style (10 tiles of `manifest-full.json`, pixelmatch threshold 0.1, `--metatile 1 --gutter 1`):

| Pass | Note |
| --- | --- |
| Trees | [trees.md](trees.md) — crown sprite was drawn outside the buffer; shadow from the blurred crown silhouette |
| Labels | [labels.md](labels.md) — new `labels_full.rs` (streets, areas, water, places, house numbers) from the project's PAL settings |
| Ground & streets | [ground.md](ground.md) — Multiply textures, kerb inner shadow, QGIS draw order |
| Buildings & symbols | [buildings-symbols.md](buildings-symbols.md) — building shadow/lines, road markings, street furniture, scale gates |

**Mean pixelmatch: 16.96 % → 3.82 %** on the old base (z17–z20: 0.9–2.0 %, z15/16: 6–11 %). After the rebase on main and the fix passes: **2.42 %** against main's new style (z17–z20: 1.0–2.4 %, z15/16: 2.2–4.9 %), see [`docs/parity/2026-10-16-after-main-rebase.md`](../../../docs/parity/2026-10-16-after-main-rebase.md).

| Tile | Before | After |
| --- | ---: | ---: |
| 15/17605/10752 | 23.2 % | 11.0 % |
| 15/17606/10752 | 25.6 % | 7.1 % |
| 16/35211/21505 | 19.3 % | 6.2 % |
| 16/35212/21505 | 20.2 % | 6.0 % |
| 17/70422/43011 (Herrfurthplatz) | 15.8 % | 1.5 % |
| 17/70425/43010 | 14.7 % | 2.0 % |
| 18/140845/86023 | 14.9 % | 1.1 % |
| 18/140851/86021 | 10.8 % | 1.0 % |
| 19/281691/172046 | 16.0 % | 0.9 % |
| 20/563382/344092 | 9.2 % | 1.2 % |

Images in [`pr/`](pr/): QGIS (main's style) · Rust after the rebase · Rust now.

Largest remaining gaps: label font (project uses DejaVu Sans Condensed, falls back to Arial when not installed), water body effects, landuse texture rotation, `layer` buckets, some foreground feature symbols. Details in the four notes.
