# PostgreSQL Tuning for LDBC SNB Benchmarks

Recommended settings for Apache AGE 1.6 on PostgreSQL 17 running LDBC SNB
Interactive benchmarks at SF0.1 – SF1000 on a **32-vCPU / 256 GB RAM** host.

These settings **cannot be applied automatically** on managed services (e.g.
HorizonDB on Azure). Apply them via `ALTER DATABASE` (takes effect on the next
connection) or through the service's server-parameter portal.

---

## Apply via SQL (managed or self-managed)

```sql
-- Scale work_mem to SF:
--   SF0.1–SF1   →  128MB
--   SF10–SF100  →  512MB
--   SF1000      →  1GB

ALTER DATABASE postgres SET work_mem                         = '512MB';
ALTER DATABASE postgres SET maintenance_work_mem             = '4GB';
ALTER DATABASE postgres SET max_parallel_workers_per_gather  = 8;
ALTER DATABASE postgres SET max_parallel_maintenance_workers = 8;
ALTER DATABASE postgres SET parallel_setup_cost              = 100;
ALTER DATABASE postgres SET parallel_tuple_cost              = 0.01;
ALTER DATABASE postgres SET random_page_cost                 = 1.1;
ALTER DATABASE postgres SET effective_cache_size             = '192GB';
ALTER DATABASE postgres SET checkpoint_completion_target     = 0.9;
ALTER DATABASE postgres SET wal_buffers                      = '256MB';
ALTER DATABASE postgres SET max_wal_size                     = '16GB';
ALTER DATABASE postgres SET min_wal_size                     = '2GB';

-- The following require server-wide config (postgresql.conf) and a RESTART —
-- they cannot be set via ALTER DATABASE. On managed services, set these
-- through the portal / server-parameters page.
--   shared_buffers        = 64GB  (25% of RAM; restart required)
--   max_worker_processes  = 32    (one per vCPU)
--   max_parallel_workers  = 24    (most cores, leave ~8 for client/leader/autovacuum)
--   max_connections       = 200   (16 driver threads × pool + headroom)
```

Verify after connecting:

```sql
SHOW work_mem;
SHOW maintenance_work_mem;
SHOW shared_buffers;
```

---

## Self-managed VM: apply via postgresql.conf

Run `scripts/configure-postgres.sh` (requires sudo, PostgreSQL on the host):

```bash
sudo bash scripts/configure-postgres.sh --sf 100
```

`shared_buffers = 64GB` (25% of 256 GB RAM) is set by `configure-postgres.sh`
but **requires a full PostgreSQL restart** to take effect — it cannot be set
via `ALTER DATABASE`. The same applies to `max_worker_processes`,
`max_connections`, and `max_prepared_transactions`. On a managed service,
choose a tier with sufficient shared memory and worker capacity, or set
these via the server-parameters portal (which usually handles the restart).

---

## Why each setting matters

| Setting | Reason |
|---|---|
| `shared_buffers = 64GB` | 25% of 256 GB RAM. Caches hot index/edge pages — single biggest lever for AGE traversal latency. Requires restart. |
| `work_mem` | Hash aggregations in IC3/IC6/IC9 spill to disk at default 4 MB on SF10+. 512 MB keeps them in RAM across 8 parallel workers. |
| `maintenance_work_mem = 4GB` | Index builds on 180 M-row edge tables at SF1000 require this to avoid disk spill. Set before `create-indexes.sql`. |
| `max_worker_processes = 32` | One per vCPU. Hard cap on background workers; must include autovacuum, replication, and parallel queries. Requires restart. |
| `max_parallel_workers = 24` | Pool that the planner draws from for parallel queries. Leaves ~8 cores for the leader process, client connections, and autovacuum. |
| `max_parallel_workers_per_gather = 8` | AGE graph traversals can use parallel workers when the plan has parallel-safe nodes. 8 matches the per-query slice of the 24-worker pool. |
| `max_connections = 200` | LDBC driver runs with `thread_count=16` and Hikari pool = thread_count, plus admin/monitoring/autovacuum workers. Requires restart. |
| `random_page_cost = 1.1` | Tells the planner SSD/NVMe random I/O ≈ sequential. Prevents it from preferring nested-loop seq scans over index scans on large edge tables. |
| `effective_cache_size = 192GB` | Planner cost estimate for OS page cache (~75% of RAM). Higher value makes the planner prefer index scans. Does not allocate memory. |
| `wal_buffers / max_wal_size = 16GB` | Reduce WAL flush and checkpoint frequency during bulk loads and IU-heavy benchmark runs. |

---

## Local development sizing — macOS / 16 GB Mac

For local SF0.1–SF3 benchmarks on a developer laptop (Apple M2 Pro, 12 cores,
16 GB RAM, running the AGE Docker container), the 256 GB / 32 vCPU sizing
above is far too large. Apply these scaled-down values instead. They were
applied via `ALTER SYSTEM` + a container restart against the
`apache/age:release_PG18_1.7.0` container and tested at SF3 + thread_count=4:

```sql
-- Reload-only (no restart needed):
ALTER SYSTEM SET effective_cache_size           = '10GB';
ALTER SYSTEM SET work_mem                       = '64MB';
ALTER SYSTEM SET maintenance_work_mem           = '1GB';
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;
ALTER SYSTEM SET max_parallel_workers            = 8;
ALTER SYSTEM SET max_parallel_maintenance_workers = 4;
ALTER SYSTEM SET parallel_setup_cost             = 100;
ALTER SYSTEM SET parallel_tuple_cost             = 0.01;
ALTER SYSTEM SET random_page_cost                = 1.1;
ALTER SYSTEM SET effective_io_concurrency        = 200;
ALTER SYSTEM SET checkpoint_completion_target    = 0.9;
ALTER SYSTEM SET jit                             = off;
SELECT pg_reload_conf();

-- Restart-required (need `docker restart <container>` after these):
ALTER SYSTEM SET shared_buffers       = '4GB';   -- 25% of 16 GB
ALTER SYSTEM SET wal_buffers          = '64MB';
ALTER SYSTEM SET max_wal_size         = '4GB';   -- caution: must fit in container volume
ALTER SYSTEM SET min_wal_size         = '1GB';
ALTER SYSTEM SET max_connections      = 50;
ALTER SYSTEM SET max_worker_processes = 12;      -- one per M2 Pro core
```

**Volume sizing pitfall**: The default Docker Desktop disk allocation may be
60 GB or less. `max_wal_size = 4GB` plus the SF3 snapshot (~11 GB) plus the
Docker build cache and other images can fill the VM disk during a restart's
WAL replay, causing PG to abort recovery with `No space left on device`. If
that happens, run `docker builder prune -af` to free build cache before
restarting, or lower `max_wal_size` to `512MB` for tight-disk setups.

| Setting | Production (256 GB / 32 vCPU) | Laptop (16 GB / 12 core) |
|---|---|---|
| `shared_buffers` | 64 GB | 4 GB |
| `effective_cache_size` | 192 GB | 10 GB |
| `work_mem` | 512 MB | 64 MB |
| `maintenance_work_mem` | 4 GB | 1 GB |
| `max_worker_processes` | 32 | 12 |
| `max_parallel_workers` | 24 | 8 |
| `max_parallel_workers_per_gather` | 8 | 4 |
| `max_connections` | 200 | 50 |
| `max_wal_size` | 16 GB | 4 GB |

---

## maintenance_work_mem for index builds

The `create-indexes.sql` script is called from `load-data.sh` with:

```bash
psql "$CONNECTION_STRING" \
    -c "SET maintenance_work_mem = '4GB';" \
    -f "${SCRIPT_DIR}/create-indexes.sql"
```

This `SET` is session-scoped and overrides whatever the server default is,
so index builds work correctly even if the server default is low.
