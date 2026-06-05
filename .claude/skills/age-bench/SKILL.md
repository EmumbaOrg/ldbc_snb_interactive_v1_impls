---
name: age-bench
description: Run AGE LDBC SNB Interactive v1 validate or benchmark cycles with mandatory restore discipline, results parsing, and delta reporting; invoke whenever asked to validate or benchmark the AGE implementation.
---

# age-bench — Validate / Benchmark Skill

All commands run from the `age/` directory of the repo.
Working directory assumption: `ldbc_snb_interactive_v1_impls/age/`.

---

## Modes

| Mode | Driver script | When to use |
|---|---|---|
| `validate` | `bash driver/validate.sh driver/<profile>.properties` | Correctness check against the LDBC-official oracle |
| `benchmark` | `bash driver/benchmark.sh driver/<profile>.properties` | Latency/throughput measurement |

---

## Profile Menu

### Validate profiles (`age/driver/`)

| Profile file | Scale / scope | Notes |
|---|---|---|
| `validate-local.properties` | SF3, 2000 ops | Default local validate — use for quick regression checks / implementer self-gate |
| `validate-local-10k.properties` | SF3, 10000 ops | **Main-session FINAL quality gate** — the big validation loop run after a clean review |
| `validate.properties` | HorizonDB / production | Production Horizon — read-only validate only |

### Benchmark profiles (`age/driver/`)

| Profile file | Scale / ops / warmup | Notes |
|---|---|---|
| `benchmark-local.properties` | SF3, 10K ops, 1K warmup | Default local SF3 perf run / implementer self-gate |
| `benchmark-local-50k.properties` | SF3, 50K ops, 10K warmup | **Main-session FINAL quality gate** + canonical baseline profile (`scripts/capture-baseline.sh`) |
| `benchmark.properties` | HorizonDB / production | Full Horizon run — NEVER write/benchmark against Horizon |

---

## The Restore Invariant — CRITICAL

**Always restore BEFORE and AFTER every run.** Never skip either restore.

Why: IU (Insert/Update) operations mutate the graph. Without a pre-run restore,
the graph is already in a mutated state and duplicate-row failures accumulate
silently — validation then fails for rows that appear multiple times rather than
real query regressions. Without a post-run restore, a subsequent run starts
dirty. The restore is cheap insurance; omitting it invalidates results.

```bash
bash scripts/restore-database.sh   # BEFORE
bash driver/<validate|benchmark>.sh driver/<profile>.properties 2>&1 | tee results/<run-name>.log
bash scripts/restore-database.sh   # AFTER
```

`restore-database.sh` drops the graph, restores from the pg_dump snapshot,
recreates indexes, and runs VACUUM ANALYZE. Allow 2–5 min at SF3.

---

## JAR Build Check

Before any run, verify the JAR is current:

```bash
mvn -q clean package -DskipTests
# JAR: target/age-1.2.0-SNAPSHOT.jar
```

If the JAR is missing or source files have changed since the last build, rebuild
before proceeding. The driver scripts require the JAR to be present.

---

## Full Validate Cycle (example — SF3 full)

```bash
# 1. Build (if needed)
mvn -q clean package -DskipTests

# 2. Restore before
bash scripts/restore-database.sh

# 3. Run validation
bash driver/validate.sh driver/validate-local.properties \
  2>&1 | tee results/validate-sf3-$(date +%Y%m%d-%H%M%S).log

# 4. Restore after
bash scripts/restore-database.sh
```

---

## Full Benchmark Cycle (example — SF3 10K)

```bash
# 1. Build (if needed)
mvn -q clean package -DskipTests

# 2. Restore before
bash scripts/restore-database.sh

# 3. Run benchmark
bash driver/benchmark.sh driver/benchmark-local.properties \
  2>&1 | tee results/bench-sf3-$(date +%Y%m%d-%H%M%S).log

# 4. Restore after
bash scripts/restore-database.sh
```

---

## Long Runs (50K final gate): Use run_in_background

For the `benchmark-local-50k` profile (the main-session final gate) and any large
run, the driver prints a status line every 30 seconds — hundreds of lines over the
run lifetime. To avoid flooding context and to receive a notification when done,
invoke via Bash with `run_in_background: true`:

- Restore before launching.
- Launch the benchmark as a background Bash call.
- You will be notified on completion; then parse results and restore after.

Do not use `&` in the command itself; use the Bash tool's `run_in_background`
parameter. Example command:

```bash
bash driver/benchmark.sh driver/benchmark-local-50k.properties \
  2>&1 | tee results/bench-sf3-50k-$(date +%Y%m%d-%H%M%S).log
```

---

## Results Parsing

After a benchmark run, parse `results/LDBC-results.json` with this snippet:

```python
python3 - <<'EOF'
import json
with open("results/LDBC-results.json") as f:
    data = json.load(f)

for m in sorted(data["all_metrics"], key=lambda x: x["name"]):
    rt = m["run_time"]
    if rt["count"] == 0:
        continue
    print(f"{m['name']:45s}  n={rt['count']:5d}  "
          f"mean={rt['mean']:7.0f}ms  "
          f"p50={rt['50th_percentile']:7.0f}ms  "
          f"p99={rt['99th_percentile']:7.0f}ms")

print(f"\nThroughput: {data['throughput']:.2f} ops/s  "
      f"Duration: {data['total_duration']/1000:.0f}s  "
      f"Total ops: {data['total_count']}")
EOF
```

### The canonical baseline

`baselines/bench-sf3-baseline.json` is the canonical SF3 baseline diffed against in both the
implementer self-gate (10K) and the main-session final gate (50K). It is **measured data**, so
it cannot be hand-written — it is generated by `scripts/capture-baseline.sh` and committed under
`age/baselines/` (NOT the gitignored `results/`). If it is absent or stale, regenerate it
before relying on any regression verdict:

```bash
CONNECTION_STRING=postgresql://postgres:postgres@localhost:5432/postgres \
  scripts/capture-baseline.sh
```

`capture-baseline.sh` restores, runs the 50K final-gate benchmark
(`benchmark-local-50k.properties`), copies `results/LDBC-results.json` to the baseline path,
and restores again. It refuses any non-local `CONNECTION_STRING`. The baseline is captured at
the 50K profile so the final gate compares like-for-like; the implementer's 10K self-gate is a
coarser smoke comparison against the same file. Refresh the baseline (and commit it) after a
landed optimization so future deltas measure against current performance.

### Delta Reporting vs a Baseline

To compare two runs, parse both logs and print deltas. Load the baseline JSON
(`baselines/bench-sf3-baseline.json`) and the new JSON, then for each op
that appears in both, report `mean_new - mean_baseline` and
`p99_new - p99_baseline`. Positive delta = regression; negative = improvement.

Example diff pattern:
```python
python3 - <<'EOF'
import json

def load_metrics(path):
    with open(path) as f:
        data = json.load(f)
    return {m["name"]: m["run_time"] for m in data["all_metrics"] if m["run_time"]["count"] > 0}

baseline = load_metrics("baselines/bench-sf3-baseline.json")   # edit path
current  = load_metrics("results/LDBC-results.json")

print(f"{'Op':45s}  {'mean_Δms':>10}  {'p99_Δms':>10}")
for name in sorted(current):
    if name not in baseline:
        continue
    dm = current[name]["mean"]        - baseline[name]["mean"]
    dp = current[name]["99th_percentile"] - baseline[name]["99th_percentile"]
    print(f"{name:45s}  {dm:+10.0f}  {dp:+10.0f}")
EOF
```

---

## Data Loading Preflight (--load, optional)

Only needed when loading a new scale factor for the first time. Skip if the
snapshot already exists.

### Environment variables (required for load)

```bash
export CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres"
# Optional:
export LDBC_DATA_DIR=/path/to/sf<N>          # default: ~/repositories/ldbc_snb_data/sf<N>
export SNAPSHOT_FILE=/tmp/ldbc_snb_snapshot.dump  # default: /tmp/ldbc_snb_snapshot.dump
```

### Local-only writes guard

**NEVER run load or benchmark (with IU writes) against HorizonDB (Horizon is shared infra).**
The connection string must point to a local PostgreSQL instance or a dedicated
test database, NOT to the production HorizonDB endpoint. Confirm the host in
`CONNECTION_STRING` before running load or benchmark scripts.

### Load command

```bash
bash scripts/load-data.sh --sf <N>
```

Load takes the following steps in order:
1. Preprocess raw LDBC CSVs → `scripts/converted/sf<N>/`
2. Bulk-load all vertices and edges into the `ldbc_snb` AGE graph
3. Create all B-tree indexes via `create-indexes.sql`
4. VACUUM ANALYZE
5. `pg_dump` snapshot to `$SNAPSHOT_FILE`

### Sanity check after load

After loading, verify the expected vertex/edge label counts:

```
Expected: 11 vertex CSV files, 15 edge CSV files
in scripts/converted/sf<N>/vertices/ and edges/
```

A mismatch in file count means the preprocessing step failed or the data
directory layout is wrong (double-nested `social_network-sf<N>-…` dirs are
common — point `LDBC_DATA_DIR` at the directory *containing* the
`social_network-…` folder, not at it directly).

---

## Known Expected Failures

**IC13 and IC14 always fail validation.** This is intentional: AGE 1.6 has no
`shortestPath()` / `allShortestPaths()` support. The SQL stubs return `-1` and
`[]` respectively. These are NOT regressions — do not investigate them.

All other queries should produce 0 failures on a clean snapshot. Any non-IC13/14
failure is a genuine regression and must be diagnosed (use the `age-results-analyst`
agent or `scripts/diagnose-failures.py`).
