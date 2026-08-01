# Performance audits (Straßenraumkarte)

Instrument the data + render pipeline, write **raw timings** under gitignored `audit/runs/`, and generate a **report + findings** you can read while an agent works in parallel.

## Quick start (Berlin Docker prep)

```bash
# From repo root — runs docker/run-berlin.sh with auditing
PERF_AUDIT_LABEL=berlin-starter ./audit/run-with-audit.sh ./docker/run-berlin.sh
```

When it finishes:

```text
audit/runs/<timestamp>_berlin-starter/
  meta.json              # host, git sha, env, status
  steps.jsonl            # one JSON object per timed step
  console.log            # full stdout/stderr
  findings.json          # machine-readable findings
  report.md              # human summary (phases, slowest steps, vs Neukölln refs)
```

Regenerate the report anytime:

```bash
./audit/write-report.py                  # latest run
./audit/write-report.py audit/runs/<id>  # specific run
```

## Parallel with agent work

1. Start the audited pipeline in one terminal (or background).
2. Continue agent / coding work in another session.
3. When the run completes, open `report.md` and `findings.json`.
4. Use `steps.jsonl` for exact durations; use findings for where to look first.

Runs do not touch git — `audit/runs/` is gitignored.

## What is timed

| Phase | Steps |
| --- | --- |
| `ingest` | PBF download (if URL), `osmium extract`, input/extract byte sizes (notes) |
| `import` | DB refresh / PostGIS ensure, `osm2pgsql`, lanes snapshot |
| `processing` | Every SQL script in `data/data_preparation.sh` (`sql:<file>`) |
| `render` | Full `xyz_tiles.py` wall time; plus `render_metatiles.jsonl` + `render_summary.json` when rendering under audit |

Enable by setting **`PERF_AUDIT_DIR`** (done automatically by `run-with-audit.sh`). Scripts no-op when unset.

## Manual / host pipeline

```bash
PERF_AUDIT_LABEL=full ./audit/run-with-audit.sh \
  ./run.sh --data data/osm/berlin-latest.osm.pbf \
  --bbox 13.4132,52.4715,13.4312,52.4821
```

Or point at an existing directory:

```bash
export PERF_AUDIT_DIR="$PWD/audit/runs/manual_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$PERF_AUDIT_DIR"
# shellcheck source=lib.sh
source audit/lib.sh && perf_init
./run.sh --data ... --bbox ...
perf_finish ok
./audit/write-report.py "$PERF_AUDIT_DIR"
```

Docker tools inherit `PERF_AUDIT_DIR` via Compose (repo is bind-mounted at `/work`, so paths stay on the host).

## Interpreting results

- **report.md — Findings:** top time sinks, phase focus, optional comparison to Neukölln reference wall times in [`reference_times.json`](reference_times.json) (from comments in `data_preparation.sh`). Smaller bboxes will look “faster than ref”; treat `regression_suspect` only after accounting for extent.
- **steps.jsonl:** ground truth for every step (`duration_ms`, `phase`, `status`, `detail`).
- **render_metatiles.jsonl:** per-metatile cost when tiles were rendered under audit.

## Files (committed)

| Path | Role |
| --- | --- |
| [`lib.sh`](lib.sh) | `perf_step` / `perf_note` helpers |
| [`record.py`](record.py) | Append meta + JSONL |
| [`run-with-audit.sh`](run-with-audit.sh) | Wrapper + console tee + report |
| [`write-report.py`](write-report.py) | `report.md` + `findings.json` |
| [`reference_times.json`](reference_times.json) | Neukölln reference seconds |
