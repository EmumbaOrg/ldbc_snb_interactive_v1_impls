# Benchmark Runbook — LDBC SNB Interactive v1 on Apache AGE / HorizonDB

This covers a fresh VM setup through to running and re-running the benchmark.
All commands run from the `age/` directory of this repository unless noted.

---

## 1. Prerequisites

### Tools

| Tool | Minimum version | Purpose |
|---|---|---|
| Java (JDK) | 11 | Run the LDBC driver |
| Maven | 3.6 | Build the driver JAR |
| Python 3 | 3.8 | Data preprocessing and loading |
| psql | matching server version | Schema setup, index creation |
| pg_dump / pg_restore | matching server version | Snapshot and restore |
| psycopg2-binary (Python) | any | `load-production-data.py` DB writes |
| pg_lsclusters / pg_ctlcluster | any | Self-managed Debian/Ubuntu only — used by `configure-postgres.sh` to locate and reload PostgreSQL; not needed for managed services or non-Debian hosts |

Install the Python dependency (creates a `.venv` in the `age/` directory):

```bash
bash scripts/install-dependencies.sh
```

### Apache AGE extension

The benchmark targets **Apache AGE 1.6** running on PostgreSQL 17.

- **HorizonDB on Azure** — AGE is pre-installed. No action needed.
- **Self-managed PostgreSQL VM** — install AGE 1.6 from source or package:
  ```bash
  # Example for Ubuntu/Debian with PostgreSQL 17 already installed
  git clone https://github.com/apache/age.git
  cd age && git checkout PG17/v1.6.0-rc0
  make PG_CONFIG=$(which pg_config) install
  psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS age;"
  ```
  See https://age.apache.org/age-manual/master/intro/install.html for full instructions.
- **Local Docker (macOS / developer laptop)** — use the official AGE Docker image.
  **`--shm-size=2g` is required.** The default Docker `/dev/shm` (64 MB) is exhausted
  by PostgreSQL's parallel hash join allocations at `max_parallel_workers≥4` during
  SF3+ benchmarks, causing a `No space left on device` crash mid-run:
  ```bash
  docker run -d \
    --name Pg17Age1.6 \
    --shm-size=2g \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=postgres \
    -p 5432:5432 \
    apache/age:release_PG17_1.6.0
  ```
  After starting, apply the local macOS tuning from `scripts/postgres-tuning.md`
  (§ "Local development sizing") and restart the container once for the
  restart-required settings (`shared_buffers`, `max_connections`, etc.).

---

## 2. Clone and build

```bash
git clone https://github.com/ldbc/ldbc_snb_interactive_v1_impls.git
cd ldbc_snb_interactive_v1_impls/age

mvn -q clean package -DskipTests
# JAR produced at: target/age-1.2.0-SNAPSHOT.jar
```

---

## 3. Environment variables

Set these before running any script. `CONNECTION_STRING` is required; the
others have defaults that work for a single-machine setup.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CONNECTION_STRING` | **yes** | — | PostgreSQL connection URL used by all scripts and the benchmark driver |
| `LDBC_DATA_DIR` | no | `~/repositories/ldbc_snb_data/sf<N>` | Directory containing the `social_network-sf<N>-CsvComposite-LongDateFormatter` folder; passed to `preprocess_ldbc.py` as `--data-dir` |
| `SNAPSHOT_FILE` | no | `/tmp/ldbc_snb_snapshot.dump` | Path for the pg_dump snapshot written by `load-data.sh` and read back by `restore-database.sh`; override if `/tmp` is too small for your scale factor |
| `PGCONF` | no | auto-detected | Full path to `postgresql.conf`; only needed by `configure-postgres.sh` when auto-detection fails on non-Debian hosts |

```bash
export CONNECTION_STRING="postgresql://<user>:<password>@<host>:<port>/<database>"

# Examples:
export CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres"
export CONNECTION_STRING="postgresql://benchuser:secret@horizondb.azure.example.com:5432/postgres"

# Optional overrides:
export LDBC_DATA_DIR=/data/ldbc/sf100
export SNAPSHOT_FILE=/data/snapshots/ldbc_sf100.dump
```

---

## 4. Apply PostgreSQL tuning

Recommended values below assume a **32-vCPU / 256 GB RAM** PostgreSQL host.
For other host sizes, scale by the rules in `scripts/postgres-tuning.md`.

### Managed service (HorizonDB on Azure, RDS, Flexible Server, etc.)

Run the following SQL once via psql or the service portal. Scale `work_mem`
and `maintenance_work_mem` to your scale factor (see `scripts/postgres-tuning.md`
for guidance):

```sql
ALTER DATABASE postgres SET work_mem                        = '512MB';   -- SF10–SF100; use 1GB for SF1000, 128MB for SF≤1
ALTER DATABASE postgres SET maintenance_work_mem            = '4GB';     -- required for index builds
ALTER DATABASE postgres SET max_parallel_workers_per_gather = 8;
ALTER DATABASE postgres SET random_page_cost                = 1.1;       -- SSD/NVMe
ALTER DATABASE postgres SET effective_cache_size            = '192GB';
ALTER DATABASE postgres SET checkpoint_completion_target    = 0.9;
ALTER DATABASE postgres SET wal_buffers                     = '256MB';
ALTER DATABASE postgres SET max_wal_size                    = '16GB';
ALTER DATABASE postgres SET min_wal_size                    = '2GB';
```

The following must be set in the service's server-parameters portal (require
a restart and cannot be set via `ALTER DATABASE`):

```
shared_buffers        = 64GB
max_worker_processes  = 32
max_parallel_workers  = 24
max_connections       = 200
```

### Self-managed VM

```bash
sudo bash scripts/configure-postgres.sh --sf 100   # adjust SF
```

`shared_buffers = 64 GB`, `max_worker_processes`, `max_connections`, and
`max_prepared_transactions` all require a full PostgreSQL restart to take
effect (not just a reload). All other settings reload immediately.

If `postgresql.conf` is not found automatically (non-Debian host), set `PGCONF`:

```bash
sudo PGCONF=/etc/postgresql/17/main/postgresql.conf bash scripts/configure-postgres.sh --sf 100
```

---

## 5. Prepare LDBC SNB raw data

### What you need

For each scale factor you need two separate datasets:

| Dataset | Used by | Notes |
|---|---|---|
| Social network graph (CsvComposite + LongDateFormatter) | `load-data.sh` (graph load) | Contains `dynamic/` and `static/` subdirs |
| Substitution parameters | `benchmark.properties` / `validate.properties` | Pre-generated query parameters matching the graph |

### Where to get the data

> **One-shot:** `bash scripts/download-ldbc-data.sh --sf <N>` (default SF3) downloads,
> extracts, and verifies the graph, substitution params, *and* the validation-params
> oracle (§11.1) into `age/datasets/`. It does not touch the DB — run
> `scripts/load-data.sh --sf <N>` afterwards to build the snapshot. The manual steps
> below remain as reference / for unsupported scale factors.

LDBC publishes pre-generated datasets for all supported scale factors.
Catalogue: https://ldbcouncil.org/benchmarks/snb/datasets/ — the v1 artifacts live under
`https://datasets.ldbcouncil.org/snb-interactive-v1/` (graph) and
`.../snb-interactive-v1-parameters/` (substitution params).

Each scale factor is distributed as two separate archives:
- **Social network graph** — `social_network-sf<N>-CsvComposite-LongDateFormatter.tar.zst`
- **Substitution parameters** — `substitution_parameters-sf<N>.tar.zst`

Download and extract both before proceeding.

### Expected directory layout

```
<data-root>/                                    ← set as LDBC_DATA_DIR
  social_network-sf<N>-CsvComposite-LongDateFormatter/
    dynamic/
    static/

<params-root>/
  substitution_parameters-sf<N>/
    substitution_parameters-sf<N>/              ← note: double-nested directory
      interactive_1_param.txt
      interactive_2_param.txt
      ...
```

`LDBC_DATA_DIR` must point to the directory **containing** the
`social_network-sf<N>-CsvComposite-LongDateFormatter` folder (i.e. `<data-root>`
above). The substitution parameters path is set directly in `benchmark.properties`
(§7).

---

## 6. Load data (one-time per scale factor)

This step preprocesses the raw CSVs, loads the graph into AGE, creates all
indexes, runs VACUUM ANALYZE, and takes a pg_dump snapshot.

```bash
export CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres"
# Optional: export LDBC_DATA_DIR=/path/to/sf0.1

bash scripts/load-data.sh --sf 0.1
```

What it does (in order):

1. **Preprocess** — runs `preprocess_ldbc.py` to convert raw LDBC CSVs into
   agefreighter-compatible CSVs under `scripts/converted/sf<N>/`
2. **Load** — `load-production-data.py` bulk-loads all vertices and edges into
   the `ldbc_snb` AGE graph; stores numeric properties (id, creationDate,
   birthMonth, birthDay, …) as agtype integers
3. **Index** — creates all query-performance B-tree indexes via `create-indexes.sql`
4. **VACUUM ANALYZE** — updates planner statistics
5. **Snapshot** — `pg_dump` to `$SNAPSHOT_FILE` (default `/tmp/ldbc_snb_snapshot.dump`)

The snapshot is the clean baseline used before every benchmark re-run. Do not
run the benchmark before this step completes.

Expected output files:

```
scripts/converted/sf<N>/
  vertices/   — 11 CSV files (one per vertex label)
  edges/      — 15 CSV files (one per edge label)
  agefreighter_config.json
/tmp/ldbc_snb_snapshot.dump   (or $SNAPSHOT_FILE)
```

---

## 7. Configure benchmark.properties

Three profiles are checked in under `driver/`:

| Profile | Target | When to use |
|---|---|---|
| `benchmark.properties` | HorizonDB / production | Full Horizon runs on Azure |
| `benchmark-local.properties` | Local PostgreSQL, **SF3**, 5K ops | Default local SF3 perf run |
| `benchmark-20k-5kwarmup.properties` | Local PostgreSQL, **SF3**, 20K ops + 5K warmup | Medium local run / smoke (baseline/gate profile) |

Pick the one matching your target and edit the host-specific fields below.

### Production / HorizonDB — `driver/benchmark.properties`

```properties
# Connection — must match your HorizonDB / PostgreSQL instance
age_endpoint=<host>:<port>/<database>
age_user=<user>
age_password=<password>

# Paths — must match where your LDBC data is stored
ldbc.snb.interactive.parameters_dir=/path/to/substitution_parameters-sf<N>/
ldbc.snb.interactive.updates_dir=/path/to/social_network-sf<N>-CsvComposite-LongDateFormatter/
ldbc.snb.interactive.scale_factor=<N>

# Benchmark size
operation_count=1000000
warmup=10000
thread_count=8
```

### Local SF3 — `driver/benchmark-local.properties` (already wired up)

Pre-configured for `localhost:5432/postgres` and the SF3 paths under
`age/datasets/`. Defaults: `thread_count=4`, `operation_count=5000`,
`warmup=1000`. Only override the endpoint/user/password if your local
PostgreSQL isn't on the default port/credentials.

For a quick smoke run, use `benchmark-20k-5kwarmup.properties` instead
(`operation_count=20000`, `warmup=5000`, same threads).

### Key notes (all profiles)

- `parameters_dir` must point to the directory that **directly contains**
  `interactive_1_param.txt`, `interactive_2_param.txt`, etc. Some archives
  unpack with a double-nested `substitution_parameters-sf<N>/substitution_parameters-sf<N>/`
  layout — point at the inner one in that case.
- `operation_count` is the number of operations **after** warmup.
- `thread_count` is sized to the **benchmark host's vCPU count**, not the DB host's.
  The Hikari JDBC pool (`age_connection_pool_size`) must mirror this value —
  each driver thread gets its own dedicated connection. Production default 8
  matches a Standard_D8ds_v4 driver VM; the local profiles use 4 for a laptop.
- The DB host's parallelism (`max_parallel_workers=24` on HorizonDB) is
  recruited *per query* by each driver thread, so DB cores aren't a constraint
  on driver thread count unless you push driver threads above the DB's
  parallel-worker pool.

---

## 8. Run the benchmark

Always restore the snapshot before running so the graph is in a clean state
(not mutated by prior IU operations).

### Option A — wrapper script (recommended for local SF3)

`driver/benchmark.sh` `cd`s into `age/` and invokes the driver. The properties
path is **relative to `age/`**; pass `driver/<file>` not `age/driver/<file>`.

```bash
# Step 1 — restore clean snapshot
bash scripts/restore-database.sh

# Step 2 — run benchmark against SF3 (5K ops, full local)
bash driver/benchmark.sh driver/benchmark-local.properties \
  2>&1 | tee results/bench-sf3-$(date +%Y%m%d-%H%M%S).log

# …or the 20K-op smoke variant
bash driver/benchmark.sh driver/benchmark-20k-5kwarmup.properties \
  2>&1 | tee results/bench-sf3-20k-$(date +%Y%m%d-%H%M%S).log
```

### Option B — raw java invocation (production / HorizonDB)

```bash
bash scripts/restore-database.sh

java --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
  -Xmx8g \
  -cp target/age-1.2.0-SNAPSHOT.jar \
  org.ldbcouncil.snb.driver.Client -P driver/benchmark.properties \
  2>&1 | tee /tmp/benchmark.log
```

The driver prints a status line every 30 seconds:

```
WorkloadStatusThread  Runtime [00:30.000], Operations [127], Throughput (Total) [4.23]
```

Results are written to `results/LDBC-results.json` when the workload completes.

---

## 9. Re-running the benchmark

The IU (Insert/Update) operations mutate the graph. Always restore before
re-running:

```bash
bash scripts/restore-database.sh
java --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
  -Xmx8g \
  -cp target/age-1.2.0-SNAPSHOT.jar \
  org.ldbcouncil.snb.driver.Client -P driver/benchmark.properties \
  2>&1 | tee /tmp/benchmark.log
```

`restore-database.sh` drops the graph, restores from the pg_dump snapshot,
recreates indexes, and runs VACUUM ANALYZE. It takes 2–5 minutes at SF0.1
and longer at higher scale factors.

---

## 10. Read results

```bash
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

---

## 11. Validation (correctness check)

Validation confirms that AGE's query output matches the LDBC reference output
byte-for-byte. The canonical ground truth is the **LDBC-distributed**
`validation_params-sf<N>.csv`, which was generated by the Neo4j Cypher
reference implementation and is the authoritative oracle.

> **Do NOT regenerate `validation_params-sf<N>.csv` locally against AGE.**
> A fresh AGE-generated file only validates AGE against AGE's prior output —
> drift-prone, and hides genuine regressions. See `queries/AGENTS.md`
> §"Validation against LDBC-official reference params" for the full rule.

### 11.1 One-time: download the official validation params

> `scripts/download-ldbc-data.sh` already pulls this oracle alongside the dataset.
> The manual steps below are for fetching it on its own.

Distributed as a single tarball covering SF0.1 → SF10 (~195 MB compressed,
~1.6 GB extracted):

```bash
cd age/datasets

curl -L -O https://datasets.ldbcouncil.org/interactive-v1/validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst
tar --use-compress-program=unzstd -xf validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst
```

After extraction `age/datasets/` contains `validation_params-sf0.1.csv` through
`validation_params-sf10.csv`. `driver/validate-local.properties` is already
wired to `validation_params-sf3.csv`.

### 11.2 Run full validation against LDBC SF3

```bash
# Step 1 — restore clean snapshot (validator expects pre-IU state)
bash scripts/restore-database.sh

# Step 2 — run validator against the LDBC-distributed SF3 oracle
bash driver/validate.sh driver/validate-local.properties \
  2>&1 | tee results/validate-sf3-$(date +%Y%m%d-%H%M%S).log
```

`driver/validate-local.properties` is pinned to:
- `validate_database=…/age/datasets/validation_params-sf3.csv`
- `parameters_dir=…/age/datasets/substitution_parameters-sf3/`
- `updates_dir=…/age/datasets/social_network-sf3-CsvComposite-LongDateFormatter/`
- All IC, IS, and IU operations enabled (IU writes are part of the validation sequence).

### 11.3 Expected outcome

- **IC13 and IC14** — always report failures. Intentional: AGE has no
  `shortestPath()` / `allShortestPaths()` support; the SQL stubs return `-1`
  and an empty list respectively. Not a regression.
- **All other queries** — 0 failures expected on a clean snapshot.
- Any other non-zero failure count is a genuine regression and must be
  investigated. Per `queries/AGENTS.md` §"Important caveats", do NOT contort
  the implementation to reproduce LDBC-Cypher quirks (e.g. duplicate emissions
  from undirected `-[:KNOWS]-`); document the divergence against the relevant
  query instead.

### 11.4 Other scale factors

Switch profiles by changing `validate_database`, `parameters_dir`,
`updates_dir`, and `scale_factor` to the matching SF (the dataset for that SF
must be loaded into AGE first per §6). The same `validate.sh` invocation
applies.

### 11.5 Production / HorizonDB

`driver/validate.properties` is the equivalent profile pointed at HorizonDB.
Same procedure: restore the snapshot on the target DB, then
`bash driver/validate.sh driver/validate.properties`.

---

## 12. Quick reference

| Task | Command |
|---|---|
| Build JAR | `mvn -q clean package -DskipTests` |
| Load data (first time) | `bash scripts/load-data.sh --sf 3` |
| Restore snapshot | `bash scripts/restore-database.sh` |
| Run benchmark — local SF3 | `bash driver/benchmark.sh driver/benchmark-local.properties` |
| Run benchmark — local SF3 (20K smoke) | `bash driver/benchmark.sh driver/benchmark-20k-5kwarmup.properties` |
| Run benchmark — HorizonDB | `bash driver/benchmark.sh driver/benchmark.properties` |
| Run validation — local SF3 (LDBC oracle) | `bash driver/validate.sh driver/validate-local.properties` |
| Run validation — HorizonDB | `bash driver/validate.sh driver/validate.properties` |
| Apply PostgreSQL tuning | See §4 above / `scripts/postgres-tuning.md` |
| Take a manual snapshot | `bash scripts/snapshot-database.sh` |

Wrapper scripts (`benchmark.sh`, `validate.sh`) `cd` into `age/`, so pass the
properties path as `driver/<file>`, **not** `age/driver/<file>`.

### Environment variables cheat-sheet

```bash
export CONNECTION_STRING="postgresql://<user>:<pass>@<host>:<port>/<db>"  # required
export LDBC_DATA_DIR=/data/ldbc/sf100          # default: ~/repositories/ldbc_snb_data/sf<N>
export SNAPSHOT_FILE=/data/snapshots/sf100.dump # default: /tmp/ldbc_snb_snapshot.dump
export PGCONF=/etc/postgresql/17/main/postgresql.conf  # configure-postgres.sh only
```
