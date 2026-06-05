# Horizon DB Tuning — Apache AGE 1.6 + LDBC Interactive

PostgreSQL configuration suggestions for the Horizon DB host running our
Apache AGE 1.6 LDBC SNB Interactive implementation.

**Target hardware**: 32 vCPUs, 256 GB RAM, NVMe storage.

**Workload profile**: LDBC Interactive — mixed OLTP reads (short queries
SQ1-SQ7), analytical reads (complex queries IC1-IC12), and writes
(IU2-IU8). Heavy on agtype + GIN index access; bursty concurrency.

**Repository convention**: Horizon DB is shared infrastructure. Apply
these changes coordinated with the team — do not apply ad-hoc from a
benchmark session. Local development DB (`Pg17Age1.6` Docker on dev
machines) follows a smaller version of this profile in
`scripts/configure-postgres.sh`.

---

## Why these recommendations exist

LDBC SF3 benchmarking on the local dev box (M2 Pro, 16 GB) surfaced
several PostgreSQL planner choices that hurt AGE Cypher workloads:

- Default `random_page_cost = 4.0` biases the planner toward Seq Scan
  on medium tables (Tag 16K rows, Person 24K rows at SF3) when GIN
  bitmap scan would be cheaper. Costs us ~24 ms baseline per
  Tag-anchored query at SF3, ~170 ms per Person-anchored query.
- Default `effective_io_concurrency = 1` underuses SSD/NVMe parallelism
  on bitmap heap scans.
- Default `shared_buffers = 128 MB` is too small for the SF3 working
  set; SF10+ would have constant cache misses on hot label tables.
- AGE Cypher functions aren't parallel-safe; default
  `max_parallel_workers_per_gather = 2` wastes planning cycles
  evaluating parallel plans that never run, and can OOM `/dev/shm`
  under burst.
- JIT compilation adds ~50-100 ms per call but our codebase now uses
  non-parameterized SQL exclusively (see `queries/AGE-QUIRKS.md` §13)
  so JIT cost is paid per call without amortization. Net negative.

Hardware scaling rationale:

- 256 GB RAM lets us hold most of the SF1000 working set in
  `shared_buffers` if we size it at 25%.
- 32 vCPUs supports ~50-100 concurrent backend connections without
  CPU saturation on the LDBC mix.
- NVMe storage justifies treating random and sequential I/O cost as
  near-equal in the planner.

---

## Memory (the big four)

| Setting | Value | Rationale |
|---|---|---|
| `shared_buffers` | **64 GB** | 25% of RAM rule. AGE label tables + GIN indexes are large (HAS_TAG = ~3.5B rows at SF1000); 64 GB covers the hot working set so IC reads don't hit OS cache. |
| `effective_cache_size` | **192 GB** | 75% of RAM. Planner hint that the OS page cache is large → encourages index scans over Seq Scans for cold paths. |
| `work_mem` | **256 MB** | Per-sort/hash unit. With ~50-100 concurrent active queries × ~3 work_mem allocations each (sorts, hashes, materialize) = up to ~75 GB worst case. Leaves headroom over shared_buffers. Do not raise without measuring concurrent peak. |
| `maintenance_work_mem` | **8 GB** | For ANALYZE + index builds. Bigger speeds up `denormalize-schema.sql` runs and `pg_restore` index rebuilds noticeably. |

## I/O — NVMe assumptions

| Setting | Value | Rationale |
|---|---|---|
| `random_page_cost` | **1.1** | Default 4.0 is HDD seek-time. On NVMe random ≈ sequential. Lets the planner pick GIN bitmap scans over Seq Scan for medium tables. This alone resolves the Q6/Tag Seq-Scan bias we measured locally. |
| `seq_page_cost` | 1.0 | Keep default. |
| `effective_io_concurrency` | **300** | NVMe queue depth. Improves bitmap heap scan throughput by ~2-3×. |
| `maintenance_io_concurrency` | **300** | Same, for autovacuum + index builds. |

## Connections + parallelism

| Setting | Value | Rationale |
|---|---|---|
| `max_connections` | **200** | LDBC `thread_count` × headroom for short-read replenishment + maintenance. Each connection costs ~5-10 MB plus work_mem allocations. |
| `max_worker_processes` | **32** | Total background workers = vCPU count. |
| `max_parallel_workers` | **16** | Half of total — leaves vCPUs for backend processing. |
| `max_parallel_workers_per_gather` | **0** | **Critical for AGE.** AGE Cypher functions aren't parallel-safe; the planner shouldn't try to parallelize `cypher()` calls. Also prevents `/dev/shm` blowups under burst. (Outer-SQL on side tables won't parallelize either at our table sizes, so we lose nothing.) |
| `max_parallel_maintenance_workers` | **8** | Speeds up CREATE INDEX on the multi-billion-row edge tables. |

## WAL / durability

| Setting | Value | Rationale |
|---|---|---|
| `wal_level` | `replica` | Default; replication-safe. |
| `min_wal_size` | **4 GB** | Avoid premature checkpoint pressure during bulk IUs. |
| `max_wal_size` | **32 GB** | Big WAL window prevents `checkpoint_warning` spam during IU bursts. |
| `checkpoint_completion_target` | **0.9** | Smooths the checkpoint I/O cliff. |
| `wal_buffers` | **64 MB** | Manual override of the 16 MB auto-cap; reduces fsync contention for AGE's edge-write-heavy IUs. |
| `synchronous_commit` | `on` | Keep default for correctness. Set to `off` per session only for benchmark runs where durability isn't required. |

## Logging / diagnostics

| Setting | Value | Rationale |
|---|---|---|
| `track_activity_query_size` | **8192** | AGE-generated SQL is large (cypher() blocks); default 1024 truncates queries in `pg_stat_activity`. |
| `log_min_duration_statement` | **1000** | Capture anything >1 s for post-hoc analysis without flooding the log. |
| `log_lock_waits` | `on` | Catches the AGE 1.6 MVCC lock-wait scenarios from IU3/IU7. |
| `deadlock_timeout` | `1s` | Default; do not raise. |
| `track_io_timing` | `on` | Lets `EXPLAIN (BUFFERS, ANALYZE)` show I/O wait — essential for diagnosing AGE label-table read patterns. |

## AGE-specific knobs

| Setting | Value | Rationale |
|---|---|---|
| `jit` | **`off`** | Measured locally as net-negative for AGE Cypher (JIT compile per call without amortization since we no longer use prepared statements — see `queries/AGE-QUIRKS.md` §13). Confirm at Horizon with `EXPLAIN ANALYZE` before treating this as durable; the JIT compile cost may amortize better on the multi-second IC5/IC10/IC12 queries at SF1000. |
| `jit_above_cost` | `1e8` *(if jit=on)* | Safety net: only JIT-compile queries with estimated cost above 100M units. At SF1000 only IC9/IC10/IC12 reach that — JIT compile cost is amortized over their multi-second execution. |

## Container / OS layer (not in `postgresql.conf`)

| Setting | Value | Rationale |
|---|---|---|
| Docker `--shm-size` (if containerized) | **8 GB** | Even with `parallel_workers_per_gather = 0`, AGE's internal hash tables can use `/dev/shm`. Local M2 dev box (2 GB) hits issues; production needs much more. |
| OS `huge_pages` | `try` (in `postgresql.conf`) | Lets PG use 2 MB pages for `shared_buffers` → ~10% TLB miss reduction. Requires `vm.nr_hugepages` set in sysctl beforehand (calculate: `shared_buffers / 2 MB` ≈ 32768 huge pages for 64 GB). |
| Filesystem | **xfs** or **ext4 with `noatime`** | Default ext4 with `atime` adds metadata writes to every IU. Both xfs and ext4 with `noatime` eliminate this. |
| `vm.swappiness` | **1** | Discourage swapping the PG buffer cache. |
| `vm.overcommit_memory` | **2** | Strict accounting — fail allocs rather than risk OOM killer murdering postgres. |

---

## Apply

```sql
-- Reload-only (no restart required)
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 300;
ALTER SYSTEM SET maintenance_io_concurrency = 300;
ALTER SYSTEM SET work_mem = '256MB';
ALTER SYSTEM SET maintenance_work_mem = '8GB';
ALTER SYSTEM SET effective_cache_size = '192GB';
ALTER SYSTEM SET track_io_timing = on;
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET log_min_duration_statement = 1000;
ALTER SYSTEM SET track_activity_query_size = 8192;
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET min_wal_size = '4GB';
ALTER SYSTEM SET max_wal_size = '32GB';
ALTER SYSTEM SET wal_buffers = '64MB';
ALTER SYSTEM SET max_parallel_workers_per_gather = 0;
ALTER SYSTEM SET max_parallel_maintenance_workers = 8;
ALTER SYSTEM SET jit = off;
SELECT pg_reload_conf();

-- Restart required
ALTER SYSTEM SET shared_buffers = '64GB';
ALTER SYSTEM SET max_connections = 200;
ALTER SYSTEM SET max_worker_processes = 32;
ALTER SYSTEM SET max_parallel_workers = 16;
-- then restart postgres: systemctl restart postgresql  (or container restart)
```

---

## Validate after applying

Run a small SF3 (or scale-appropriate) query to confirm the planner is
making the expected choices.

```sql
-- Person lookup via GIN (should use Bitmap Index Scan, not Seq Scan)
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM cypher('ldbc_snb', $$
  MATCH (p:Person {id: 933}) RETURN p.firstName, p.lastName
$$) AS x(fn agtype, ln agtype);
```

**Expected output markers**:
- `Bitmap Index Scan on gin_person` (not `Seq Scan on "Person"`)
- `Buffers: shared hit=K` in low double-digits, not thousands
- `Execution Time` < 10 ms

If any of those fail, the knob didn't apply (check `SHOW
random_page_cost`) or the planner needs an `ANALYZE ldbc_snb."Person"`
to refresh stats after the change.

---

## What this configuration does NOT cover

This document is about PostgreSQL/AGE server configuration. Several
performance issues live outside it and are tracked separately:

- **Query-side optimizations** — Cypher rewrites, side-table designs,
  index strategy. See `optimization-plan-2026-05-15.md` and the per-query
  files in `queries/*.sql`.
- **Driver/JDBC** — the `age_parameterized_queries=` empty rule plus
  Hikari pool sizing. See `driver/*.properties` and `queries/AGE-QUIRKS.md`
  §13 / §15.
- **Bulk-load tuning** — separate concerns for `pg_restore` /
  `load-production-data.py` (different `maintenance_work_mem`,
  `synchronous_commit = off` during load, etc.). See
  `scripts/configure-postgres.sh` for what the local dev box uses; the
  production loader should follow a similar pattern adapted to the
  larger memory budget.

---

## Open questions for the Horizon team

1. **NVMe vs network-attached storage** — these recommendations assume
   local NVMe. If Horizon uses AWS EBS / Azure Premium Disk, raise
   `random_page_cost` to 1.5-2.0 and lower `effective_io_concurrency`
   to 100-200.
2. **Multi-tenant concerns** — if other workloads share the host,
   reduce `shared_buffers` proportionally and document the budget.
3. **Replication lag tolerance** — if synchronous replication is
   required, `synchronous_commit = remote_apply` will throttle IU
   throughput. Measure under expected commit rate before adopting.
4. **Existing tuning** — confirm what's currently set via
   `SHOW ALL;` before applying these; some Horizon-specific values
   may already exist and shouldn't be clobbered.

---

*Document created 2026-05-15 as part of the Phase 3 optimization work.
Cross-references: `optimization-plan-2026-05-15.md` §7a (parameterized
path reversal), `queries/AGE-QUIRKS.md` §13/§15 (GIN-bind issue),
`scripts/configure-postgres.sh` (local dev counterpart).*
