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

LDBC publishes pre-generated datasets for all supported scale factors.
Download from: https://github.com/ldbc/ldbc_snb_interactive_v2_impls/blob/main/docs/datasets.md

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

Edit `driver/benchmark.properties` for your environment:

```properties
# Connection — must match your HorizonDB / PostgreSQL instance
age_endpoint=<host>:<port>/<database>
age_user=<user>
age_password=<password>

# Paths — must match where your LDBC data is stored
ldbc.snb.interactive.parameters_dir=/path/to/substitution_parameters-sf0.1/substitution_parameters-sf0.1/
ldbc.snb.interactive.updates_dir=/path/to/social_network-sf0.1-CsvComposite-LongDateFormatter/
ldbc.snb.interactive.scale_factor=0.1

# Benchmark size
operation_count=1000000
warmup=10000
thread_count=8
```

Key notes:
- `parameters_dir` must point to the **inner** directory that directly contains
  `interactive_1_param.txt`, `interactive_2_param.txt`, etc.  
  If your archive unpacks as `substitution_parameters-sf0.1/substitution_parameters-sf0.1/`,
  point to the inner one.
- `operation_count` is the number of operations **after** warmup.
- `thread_count` is sized to the **benchmark host's vCPU count**, not the DB host's.
  Default 8 matches a Standard_D8ds_v4 (8 vCPU / 32 GB) driver VM. The Hikari JDBC
  pool (`age_connection_pool_size`) must mirror this value — each driver thread
  gets its own dedicated connection. For a 16-vCPU driver bump both to 16; for
  a 4-vCPU driver drop both to 4.
- The DB host's parallelism (`max_parallel_workers=24`) is recruited *per query*
  by each driver thread, so DB cores aren't a constraint on driver thread count
  unless you push driver threads above the DB's parallel-worker pool.

---

## 8. Run the benchmark

Always restore the snapshot before running so the graph is in a clean state
(not mutated by prior IU operations):

```bash
# Step 1 — restore clean snapshot
bash scripts/restore-database.sh

# Step 2 — run benchmark
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

Validation confirms that query results match the expected LDBC reference output.
It requires a `validation_params-sf<N>.csv` reference file.

```bash
# Edit driver/validate.properties with correct connection and paths, then:
bash scripts/run-local-validation.sh
```

`run-local-validation.sh` generates a fresh `validation_params.csv` from the
current implementation, restores the snapshot, then runs the validator.

Expected outcome for the current implementation: only IC13 and IC14 report
failures (both are intentionally disabled). All other queries should pass.

---

## 12. Quick reference

| Task | Command |
|---|---|
| Build JAR | `mvn -q clean package -DskipTests` |
| Load data (first time) | `bash scripts/load-data.sh --sf 0.1` |
| Restore before benchmark | `bash scripts/restore-database.sh` |
| Run benchmark | `java --add-opens java.base/sun.nio.ch=ALL-UNNAMED -Xmx8g -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client -P driver/benchmark.properties` |
| Run validation | `bash scripts/run-local-validation.sh` |
| Apply PostgreSQL tuning | See §4 above / `scripts/postgres-tuning.md` |
| Take a manual snapshot | `bash scripts/snapshot-database.sh` |

### Environment variables cheat-sheet

```bash
export CONNECTION_STRING="postgresql://<user>:<pass>@<host>:<port>/<db>"  # required
export LDBC_DATA_DIR=/data/ldbc/sf100          # default: ~/repositories/ldbc_snb_data/sf<N>
export SNAPSHOT_FILE=/data/snapshots/sf100.dump # default: /tmp/ldbc_snb_snapshot.dump
export PGCONF=/etc/postgresql/17/main/postgresql.conf  # configure-postgres.sh only
```
