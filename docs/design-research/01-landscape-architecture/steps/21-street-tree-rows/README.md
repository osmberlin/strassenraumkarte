# LA 21 — street-tree rows

Tree vocabulary item 3 from the mission: *street tree row — same symbol, more uniform in colour.* Before, every street tree picked symbol and tone from its own id, so a row on Allerstraße mixed three symbols and six tones.

- The tree query now also returns the name of the nearest named road within ~12 m (`highway`, `type = 'road'`, KNN on the GiST index).
- A tree without `genus` that stands near a street and **not** inside lawn/park or woodland takes symbol and tone from a hash of the street name, with a small per-tree lightness jitter so the row is uniform but not stamped. Default crown 5.5 m when `diameter_crown` is missing.
- Park trees keep the varied generic symbols; trees with a `genus` keep their genus symbol.

**Look at:** `rows.jpg` (scene B, Allerstraße: before | after).
