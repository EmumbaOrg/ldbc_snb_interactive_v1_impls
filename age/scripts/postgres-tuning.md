# PostgreSQL Tuning for LDBC SNB Benchmarks

Recommended settings for Apache AGE 1.6 on PostgreSQL 17 running LDBC SNB
Interactive benchmarks at SF0.1 – SF1000 on a 32 GB host.

These settings **cannot be applied automatically** on managed services (e.g.
HorizonDB on Azure). Apply them via `ALTER DATABASE` (takes effect on the next
connection) or through the service's server-parameter portal.

---

## Apply via SQL (managed or self-managed)

```sql
-- Scale work_mem to SF:
--   SF0.1–SF1   →  64MB
--   SF10–SF100  →  256MB
--   SF1000      →  512MB

ALTER DATABASE postgres SET work_mem                        = '256MB';
ALTER DATABASE postgres SET maintenance_work_mem            = '2GB';
ALTER DATABASE postgres SET max_parallel_workers_per_gather = 4;
ALTER DATABASE postgres SET max_parallel_workers            = 8;
ALTER DATABASE postgres SET parallel_setup_cost             = 100;
ALTER DATABASE postgres SET parallel_tuple_cost             = 0.01;
ALTER DATABASE postgres SET random_page_cost                = 1.1;
ALTER DATABASE postgres SET effective_cache_size            = '24GB';
ALTER DATABASE postgres SET checkpoint_completion_target    = 0.9;
ALTER DATABASE postgres SET wal_buffers                     = '256MB';
ALTER DATABASE postgres SET max_wal_size                    = '4GB';
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

`shared_buffers = 8GB` (25% of 32 GB RAM) is set by `configure-postgres.sh`
but **requires a full PostgreSQL restart** to take effect — it cannot be set
via `ALTER DATABASE`. On a managed service, choose a tier with sufficient
shared memory instead.

---

## Why each setting matters

| Setting | Reason |
|---|---|
| `work_mem` | Hash aggregations in IC3/IC6/IC9 spill to disk at default 4 MB on SF10+. 256 MB keeps them in RAM across 4 parallel workers. |
| `maintenance_work_mem` | Index builds on 180 M-row edge tables at SF1000 require this to avoid disk spill. Set before `create-indexes.sql`. |
| `max_parallel_workers_per_gather` | AGE graph traversals can use parallel workers when the plan has parallel-safe nodes. |
| `random_page_cost = 1.1` | Tells the planner SSD/NVMe random I/O ≈ sequential. Prevents it from preferring nested-loop seq scans over index scans on large edge tables. |
| `effective_cache_size = 24GB` | Planner cost estimate for OS page cache. Higher value makes the planner prefer index scans. Does not allocate memory. |
| `wal_buffers / checkpoint_*` | Reduce WAL flush frequency during bulk data loads. |

---

## maintenance_work_mem for index builds

The `create-indexes.sql` script is called from `load-data.sh` with:

```bash
psql "$CONNECTION_STRING" \
    -c "SET maintenance_work_mem = '2GB';" \
    -f "${SCRIPT_DIR}/create-indexes.sql"
```

This `SET` is session-scoped and overrides whatever the server default is,
so index builds work correctly even if the server default is low.
