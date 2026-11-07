# Ink 05 — street names and a switchable accent

- **Street names** from `label_highway`, drawn with resvg `textPath` in *Hoefler Text Italic* with a paper halo; placed at world-stable positions (middle of the full street line, repeated every ~560 px), so neighbouring tiles agree.
- **Accent category is a render parameter**: `SRK_ACCENT=playground` (default) | `bench` | `tree` | `none`. Everything else stays ink. Benches are now small upright glyphs (z18+, or always when they are the accent).

```bash
SRK_ACCENT=bench srk-render --layers ink …
```

**Look at:** `accent-playground.jpg` vs `accent-bench.jpg` (same area), `accent-tree.jpg`, labels in `sheet.jpg`.
