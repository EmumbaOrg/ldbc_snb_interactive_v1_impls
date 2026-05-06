# Plan: Make AGE LDBC query execution fast (Phases C, D, E)

**Audience**: an AI agent (Sonnet 4.6) tasked with implementing the three performance changes described below. The plan is opinionated about specific files, line shapes, and command invocations to remove ambiguity. **Read the entire plan before writing any code.**

**Working directory**: `/Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age`. All relative paths in this plan are rooted there unless they begin with `/`.

**Out of scope**:
- IC13 / IC14 stub handlers and their ~50% Incorrect rate. They are intentionally stubbed and the validator will continue to report them as Incorrect after these changes — that is expected, do not "fix" them as part of this work.
- Query semantics. Do NOT alter the WHERE / RETURN / ORDER BY / LIMIT clauses of any `.sql` file. Phase E rewrites how parameters are *bound*; it does not change the *meaning* of any query.
- The `agefreighter` data load path. Loading is already complete — assume the graph `ldbc_snb` exists and the snapshot at `/tmp/ldbc_snb_snapshot.dump` is restorable.
- Driver internals (`ldbcouncil/snb/driver`). Only the AGE implementation under `age/src/main/java/org/ldbcouncil/snb/impls/workloads/age/` and `age/scripts/` and `age/queries/` are in scope.

---

## 1. Goals and success metrics

**Current state (verified 2026-05-05)**:
- Validation throughput on the 2K-op SF0.1 subset: **~1.14 ops/sec** (29m 22s wall clock at thread_count=1).
- 138K-op full SF0.1 validation projects to ~33 hours.
- Prior phases A (drop per-query `SET search_path`) and B (HikariCP pool) are already merged. They removed two round trips per query and unblocked future thread_count>1 runs. Phase C/D/E are the next levers.

**Target state after Phases C+D+E**:

| Metric | Current | Target |
|---|---|---|
| 2K-subset wall clock at thread_count=1 | 29m 22s | **≤ 8 min** (≥ 4× speedup) |
| ops/sec at thread_count=1 | ~1.14 | **≥ 4** |
| ops/sec at thread_count=8 | not yet measured | **≥ 20** |
| 138K full SF0.1 wall clock at thread_count=8 | ~33 hr | **≤ 2 hr** |
| Correctness vs current | — | **identical**: subset must report only IC13 (96/96 incorrect) and IC14 (96/96 incorrect). **No new Incorrect operation types in any query.** |

**Phase contributions to the target** (independent estimates — implementer should NOT skip a phase to "save time"):

| Phase | Expected speedup at thread_count=1 |
|---|---|
| C — index strategy | 1.5–2× (IC2/IC3/IC9 range scans, tag/place lookups) |
| D — postgresql.conf OLTP tuning | 1.3–1.6× (work_mem prevents disk sort spills; shared_buffers reduces reads) |
| E — parameterized cypher() | 1.5–2× (eliminates per-call parse + plan; AGE re-parses Cypher on every text-different SQL) |

Combined, the phases compose multiplicatively (expected ~4×). thread_count=8 then adds another 4–6× by parallelism on a 4-core host (PostgreSQL 17 will not perfectly scale to 8 connections on 4 CPUs).

---

## 2. Environment facts

The implementer needs to know these before touching anything:

- **PostgreSQL** runs in a Docker container named `age-pg17-local`. Image: `apache/age:release_PG17_1.6.0`. Confirm with `docker ps`.
- **PG version** is 17.7 inside the container.
- **Connection** from host: `postgresql://postgres:postgres@localhost:5432/postgres`.
- **AGE graph** is named `ldbc_snb` (configured via `age_graph_name=ldbc_snb` in `driver/validate.properties`).
- **Config file inside container**: `/var/lib/postgresql/data/postgresql.conf`. Use `ALTER SYSTEM SET ...` + `SELECT pg_reload_conf();` for non-restart-requiring settings — that writes to `postgresql.auto.conf` and preserves the operator's hand-edits to the main config file. Restart-requiring settings (e.g., `shared_buffers`) need `docker restart age-pg17-local`.
- **Validation snapshot** for restore-between-runs: `/tmp/ldbc_snb_snapshot.dump`. The script `scripts/restore-database.sh` handles the AGE OID fixup after restore — always use that script, do not invoke `pg_restore` directly.
- **Validation params** (the 2K subset is the iteration target, the 138K full file is the final report target):
  - 2K subset: `/tmp/ldbc_sf01/validation_params-sf0.1-subset.csv`
  - 138K full:  `/tmp/ldbc_sf01/validation_params-sf0.1.csv`
- **Build**: `mvn -q clean package -DskipTests` from the `age/` directory. Output JAR: `target/age-1.2.0-SNAPSHOT.jar`.
- **Run a validation**: `java -Xmx8g -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client -P driver/validate.properties`
- **Java version**: 11 (per `pom.xml`'s `maven.compiler.source`). Do not use Java 17-only APIs.

---

## 3. Implementation order (NON-NEGOTIABLE)

Phases must run in C → D → E order, with a full validation pass between each. Reasons:

1. **C before D**: indexing changes how the planner picks scans. Tuning postgresql.conf without indexes in place produces measurements you'll have to re-do.
2. **D before E**: Phase E is a code change; if a perf regression appears after E, you need to know whether the postgresql.conf change is at fault or the prepared-statement migration is. Doing D first eliminates one variable.
3. **Each phase has its own validation gate.** Do not start the next phase until the current phase passes the validation criteria in §6. This is how you bisect a regression.

Implementation cadence:

```
Phase C: indexes
  ├── audit existing indexes (§4.2)
  ├── add missing indexes (§4.3)
  ├── VACUUM ANALYZE (§4.4)
  ├── restore snapshot
  ├── run 2K subset, time it, diff Incorrect set
  └── go/no-go gate: pass §4.5 → continue, fail → fix or revert

Phase D: postgresql.conf
  ├── ALTER SYSTEM SET each tunable (§5.2)
  ├── docker restart (for shared_buffers)
  ├── verify with SHOW (§5.4)
  ├── restore snapshot
  ├── run 2K subset, time it, diff Incorrect set
  └── go/no-go gate: pass §5.5 → continue, fail → revert ALTER SYSTEM (§5.6)

Phase E: parameterized cypher()
  ├── sanity-check 3-arg cypher() against the live DB (§6.3.1)
  ├── add agtype JSON formatter (§6.4.1)
  ├── add per-connection PreparedStatement cache (§6.4.4)
  ├── refactor handler base classes (§6.4.3)
  ├── migrate read queries one at a time, run 2K subset after each (§6.5)
  ├── migrate update queries one at a time, run 2K subset after each (§6.5)
  └── go/no-go gate: pass §6.7 → done, fail → revert that one query and continue (§6.8)
```

If you find yourself wanting to do two phases at once "to save time", stop. The plan is sequential because each phase's debug surface is small *if isolated* and overwhelming *if combined*.

---

## 4. Phase C — Index strategy upgrade

### 4.1 Current state

The existing index DDL is in `scripts/create-indexes.sql`. It already creates:

- GIN-on-`properties` for every vertex label (Person, Comment, Post, Forum, Tag, TagClass, City, Country, Continent, Company, University). This enables `MATCH (n:Label {id: X})` containment lookups.
- B-tree on extracted `creationDate` for Comment and Post (functional index over `CAST(agtype_object_field_text(properties,'creationDate') AS bigint)`). Enables IC2/IC3/IC4/IC7/IC9 date-range filters.
- B-tree on extracted `name` for Tag, TagClass, Country.
- B-tree on `start_id` and `end_id` for every edge label (KNOWS, HAS_CREATOR, REPLY_OF, HAS_TAG, LIKES, CONTAINER_OF, HAS_MEMBER, IS_LOCATED_IN, HAS_INTEREST, WORK_AT, STUDY_AT, HAS_TYPE, IS_SUBCLASS_OF, HAS_MODERATOR, IS_PART_OF).

This is a solid baseline. The audit below identifies what's still missing.

### 4.2 Audit existing indexes

Run this first, save the output, and diff against §4.3 to compute the delta. Do NOT skip the audit — you need to know what's already there, because rebuilding an existing GIN index on a populated graph is expensive and unnecessary.

```bash
psql "postgresql://postgres:postgres@localhost:5432/postgres" -c "
  SELECT n.nspname AS schema,
         c.relname AS table,
         i.relname AS index,
         pg_size_pretty(pg_relation_size(i.oid)) AS size,
         a.amname AS method,
         pg_get_indexdef(i.oid) AS def
  FROM pg_class c
  JOIN pg_namespace n ON c.relnamespace = n.oid
  JOIN pg_index ix ON ix.indrelid = c.oid
  JOIN pg_class i ON i.oid = ix.indexrelid
  JOIN pg_am a ON i.relam = a.oid
  WHERE n.nspname = 'ldbc_snb'
  ORDER BY c.relname, i.relname;
"
```

### 4.3 Missing indexes to add

These are the gaps observed against the LDBC Interactive query workload. Each entry includes the query types it serves and the predicate it supports, so the implementer can verify with `EXPLAIN` that the planner actually picks the index.

Add the following to `scripts/create-indexes.sql` (append to the existing file — the file is idempotent via `IF NOT EXISTS`, so re-running it is safe):

```sql
-- ---------------------------------------------------------------------------
-- Phase C additions — vertex.id functional B-tree indexes
-- The existing GIN-on-properties index supports MATCH ({id: X}) containment.
-- However, for queries that PROJECT n.id from a previously-bound vertex set
-- (e.g. RETURN friend.id ORDER BY friend.id), the planner cannot reuse the GIN
-- and falls back to a parallel sort over the entire vertex table. A functional
-- B-tree on the extracted id column lets the planner satisfy ORDER BY friend.id
-- without a sort node and provides faster equality lookup than GIN containment
-- for the hot single-id MATCH path.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_person_id   ON ldbc_snb."Person"   (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_comment_id  ON ldbc_snb."Comment"  (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_post_id     ON ldbc_snb."Post"     (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_forum_id    ON ldbc_snb."Forum"    (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_tag_id      ON ldbc_snb."Tag"      (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_tagclass_id ON ldbc_snb."TagClass" (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_city_id     ON ldbc_snb."City"     (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_country_id  ON ldbc_snb."Country"  (CAST(agtype_object_field_text(properties, 'id') AS bigint));

-- ---------------------------------------------------------------------------
-- Phase C additions — Person.firstName (IC1)
-- IC1 filters friend.firstName = $firstName across 1, 2, and 3-hop KNOWS paths.
-- The existing GIN supports {firstName: X} but only at the *original* MATCH —
-- once Person is bound transitively, the projection-side filter becomes a
-- per-row containment check.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_person_firstname ON ldbc_snb."Person" (agtype_object_field_text(properties, 'firstName'));

-- ---------------------------------------------------------------------------
-- Phase C additions — Forum.id (IS6 / IU5)
-- LdbcShortQuery6MessageForum walks Comment→REPLY_OF*→Post←CONTAINER_OF←Forum
-- and projects Forum.id; LdbcUpdate5AddForumMembership matches Forum {id: $forumId}.
-- The Forum.id functional B-tree is added above; this comment documents *why*.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Phase C additions — Message.creationDate composite covering index
-- IC2 ("recent messages by friends") and IC9 ("recent messages by friends-of-friends")
-- both filter messages by creationDate < maxDate and ORDER BY creationDate DESC.
-- A composite (creationDate, id) on the union of Comment+Post would let the planner
-- index-scan in date-desc order. AGE's per-label storage prevents a true union index;
-- the next-best is a per-label composite that includes id as a covering column.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_comment_date_id ON ldbc_snb."Comment"
  (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint) DESC,
   CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX IF NOT EXISTS idx_post_date_id    ON ldbc_snb."Post"
  (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint) DESC,
   CAST(agtype_object_field_text(properties, 'id') AS bigint));

-- ---------------------------------------------------------------------------
-- Phase C additions — Comment.length / Post.length (IC2 result tie-breaks)
-- Probably not used by the planner; documented here so the reviewer can see we
-- considered it. SKIP unless EXPLAIN ANALYZE on IC2 shows a sort spill on length.
-- ---------------------------------------------------------------------------
-- (none added)
```

### 4.4 Apply and verify

```bash
# 1. Re-run the (now extended) DDL script. IF NOT EXISTS makes re-runs cheap.
psql "postgresql://postgres:postgres@localhost:5432/postgres" \
  -f /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/scripts/create-indexes.sql

# 2. ANALYZE so the planner has stats on the new indexes.
psql "postgresql://postgres:postgres@localhost:5432/postgres" -c "
  SET search_path = ag_catalog, ldbc_snb, public;
  VACUUM ANALYZE ldbc_snb.\"Person\";
  VACUUM ANALYZE ldbc_snb.\"Comment\";
  VACUUM ANALYZE ldbc_snb.\"Post\";
  VACUUM ANALYZE ldbc_snb.\"Forum\";
  VACUUM ANALYZE ldbc_snb.\"Tag\";
  VACUUM ANALYZE ldbc_snb.\"TagClass\";
  VACUUM ANALYZE ldbc_snb.\"City\";
  VACUUM ANALYZE ldbc_snb.\"Country\";
"
# (vacuum-analyze.sh exists at scripts/vacuum-analyze.sh; if it covers the same
# tables, prefer running it instead.)

# 3. Verify a sample query uses the new index.
psql "postgresql://postgres:postgres@localhost:5432/postgres" -c "
  LOAD 'age';
  SET search_path = ag_catalog, ldbc_snb, public;
  EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM cypher('ldbc_snb', \$\$
    MATCH (p:Person {id: 933}) RETURN p.firstName, p.lastName
  \$\$) AS (firstName agtype, lastName agtype);
"
# Expected: Index Scan using idx_person_id (or gin_person), execution time < 5 ms.
# If it shows "Seq Scan on Person" — the new index is missing or stats are stale;
# re-ANALYZE.
```

### 4.5 Phase C done criteria

- [ ] `scripts/create-indexes.sql` contains all the new `CREATE INDEX IF NOT EXISTS` statements from §4.3.
- [ ] `psql -c "\\d ldbc_snb.\"Person\""` shows both `gin_person` AND `idx_person_id` AND `idx_person_firstname`.
- [ ] `EXPLAIN (ANALYZE, BUFFERS) MATCH (p:Person {id: 933}) RETURN p` shows an Index Scan, not a Seq Scan.
- [ ] After restore + 2K-subset run: total wall clock is **≤ 22 minutes** (i.e., ≥ 1.3× faster than the 29m22s baseline). Incorrect set is exactly `{IC13: 96, IC14: 96}` — no new failure types.

---

## 5. Phase D — postgresql.conf OLTP tuning

### 5.1 Current state (verified)

The container ships with PostgreSQL 17 default-ish settings:

| Setting | Current | Default for 16 GB host | Reasoning gap |
|---|---|---|---|
| `shared_buffers` | 128 MB (16384 × 8 KB) | ~4 GB | Way too small. Working set spills to OS cache → IO each fetch. |
| `effective_cache_size` | 4 GB (524288 × 8 KB) | 12 GB | Makes the planner overestimate index lookup cost vs seq scan. |
| `work_mem` | 4 MB | ~7 MB | IC2/IC3/IC9 sorts spill to disk for top-20-of-many results. |
| `maintenance_work_mem` | 64 MB | 1 GB | VACUUM and CREATE INDEX are slower than necessary. |
| `random_page_cost` | 4 | 1.1 | Tuned for HDD; we have SSD. Discourages index scans. |
| `effective_io_concurrency` | 1 | 200 | SSD can sustain many parallel reads. |
| `max_parallel_workers_per_gather` | 0 | 2 | Disables parallel query entirely. AGE benefits modestly. |
| `jit` | on | off | Each unique SQL string triggers cold JIT compile (50–500 ms each). For OLTP this is pure tax — savings never recoup cost. |

### 5.2 Target settings

These settings come from the Postgres reference impl at `postgres/config/postgresql.conf`, with two AGE-specific deviations called out below.

```sql
-- Apply via psql. ALTER SYSTEM writes to postgresql.auto.conf, which the
-- container's hand-edited postgresql.conf does NOT override.
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '12GB';
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET maintenance_work_mem = '1GB';
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
ALTER SYSTEM SET max_parallel_workers_per_gather = 2;
ALTER SYSTEM SET max_parallel_workers = 8;
ALTER SYSTEM SET max_worker_processes = 8;
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET wal_buffers = '16MB';
ALTER SYSTEM SET min_wal_size = '2GB';
ALTER SYSTEM SET max_wal_size = '8GB';
ALTER SYSTEM SET jit = off;
```

**Deviations from the postgres ref**:
- `work_mem` is **64 MB** (vs ref's 6990 kB). AGE's cypher() emits intermediate aggregations (collect(), DISTINCT, ORDER BY LIMIT 20) where 7 MB spills to disk; 64 MB is empirically enough at SF0.1. With max 8 connections × 2 parallel workers each = 16 sort slots, peak RAM usage is 16 × 64 MB = 1 GB. Within budget on a 16 GB host.
- `jit = off` is set globally here even though `AgeDbConnectionState` already passes `jit=off` per-connection via the JDBC URL. Setting it server-wide is belt-and-suspenders: protects future direct-psql usage and removes any startup-packet parsing cost.

**Settings deliberately NOT changed**:
- `max_connections` — current 100 is fine; we target pool size 8.
- `default_statistics_target` — leave at 100; bumping to 1000 helps wide histograms but the AGE workload is selective on id, not range-skewed.
- `synchronous_commit` — leave at on; turning off risks data loss on the update operations and we're not durability-bound.

### 5.3 Apply

```bash
# 1. Apply ALTER SYSTEM settings
psql "postgresql://postgres:postgres@localhost:5432/postgres" <<'SQL'
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '12GB';
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET maintenance_work_mem = '1GB';
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
ALTER SYSTEM SET max_parallel_workers_per_gather = 2;
ALTER SYSTEM SET max_parallel_workers = 8;
ALTER SYSTEM SET max_worker_processes = 8;
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET wal_buffers = '16MB';
ALTER SYSTEM SET min_wal_size = '2GB';
ALTER SYSTEM SET max_wal_size = '8GB';
ALTER SYSTEM SET jit = off;
SQL

# 2. shared_buffers, max_worker_processes, wal_buffers require restart.
# The rest can be picked up via reload, but restarting is simpler and removes
# ambiguity about which got applied.
docker restart age-pg17-local

# 3. Wait until PG accepts connections.
until psql "postgresql://postgres:postgres@localhost:5432/postgres" -c "SELECT 1" >/dev/null 2>&1; do
  sleep 2
done
```

### 5.4 Verify

```bash
psql "postgresql://postgres:postgres@localhost:5432/postgres" -c "
  SELECT name, setting, unit, source
  FROM pg_settings
  WHERE name IN ('shared_buffers','effective_cache_size','work_mem',
                 'maintenance_work_mem','random_page_cost','effective_io_concurrency',
                 'max_parallel_workers_per_gather','jit',
                 'max_parallel_workers','max_worker_processes',
                 'checkpoint_completion_target','wal_buffers',
                 'min_wal_size','max_wal_size')
  ORDER BY name;
"
# Every row's source should be 'configuration file' (overridden by postgresql.auto.conf)
# or 'auto'. None should be 'default'.
# shared_buffers should be 524288 (= 4 GB / 8 KB).
# work_mem should be 65536 (kB).
# jit should be 'off'.
```

### 5.5 Phase D done criteria

- [ ] `SELECT setting FROM pg_settings WHERE name='shared_buffers'` returns `524288`.
- [ ] `SELECT setting FROM pg_settings WHERE name='jit'` returns `off`.
- [ ] `SELECT setting FROM pg_settings WHERE name='work_mem'` returns `65536`.
- [ ] After restore-database + 2K subset run at thread_count=1: wall clock ≤ **15 minutes** (≥ 2× over the 29m22s baseline; combines C+D gains). Incorrect set is exactly `{IC13: 96, IC14: 96}`.

### 5.6 Rollback

```sql
-- Revert all ALTER SYSTEM SETs back to default.
ALTER SYSTEM RESET shared_buffers;
ALTER SYSTEM RESET effective_cache_size;
ALTER SYSTEM RESET work_mem;
ALTER SYSTEM RESET maintenance_work_mem;
ALTER SYSTEM RESET random_page_cost;
ALTER SYSTEM RESET effective_io_concurrency;
ALTER SYSTEM RESET max_parallel_workers_per_gather;
ALTER SYSTEM RESET max_parallel_workers;
ALTER SYSTEM RESET max_worker_processes;
ALTER SYSTEM RESET checkpoint_completion_target;
ALTER SYSTEM RESET wal_buffers;
ALTER SYSTEM RESET min_wal_size;
ALTER SYSTEM RESET max_wal_size;
ALTER SYSTEM RESET jit;
-- Then docker restart age-pg17-local.
```

---

## 6. Phase E — Parameterized cypher() migration

This is the highest-risk and highest-impact phase. **Do not attempt it before Phases C and D pass their gates.**

### 6.1 Why this matters

The AGE handler today does this (`AgeListOperationHandler.executeOperation`, line 23):

```java
String sql = getQueryString(state, operation);   // text-substitutes $personId → "933"
state.logQuery(...);
try (Connection conn = state.getConnection();
     Statement stmt = conn.createStatement()) {
    if (stmt.execute(sql)) { ... }
}
```

`getQueryString` (via `AgeQueryStore.prepare`) bakes the parameter values into the SQL string. Every call produces a different SQL string. PostgreSQL's plan cache keys on text → cache miss every time. AGE's `cypher()` function eagerly parses the inner Cypher block at planning time, so we pay parse + plan + JIT-decision cost on every operation.

The fix is the **3-argument `cypher()` form**:

```sql
SELECT * FROM cypher('ldbc_snb', $$
    MATCH (p:Person {id: $personId})-[:IS_LOCATED_IN]->(c:City)
    RETURN p.firstName, p.lastName, c.id
$$, ?::agtype) AS (firstName agtype, lastName agtype, cityId agtype);
```

- The first two args (graph name and Cypher source) are string literals → planner constants → parse-once + plan-cache.
- The third arg is a JDBC bind parameter (`?` is JDBC's positional placeholder; pgjdbc translates it to `$1` server-side). Its value is an `agtype` map JSON literal: `{"personId": 933}`. AGE binds Cypher `$personId` from this map at execution time. The `::agtype` cast is mandatory — without it, JDBC sends `text` and PG complains about no implicit conversion.
- A `PreparedStatement` cached per-connection then reuses the parsed plan across calls.

Important: do NOT use PostgreSQL native `$1`/`$2`/... in the .sql files. JDBC only accepts `?` placeholders. Inside the dollar-quoted Cypher block, `$personId` is *Cypher* parameter syntax (resolved by AGE from the agtype map at execution time), NOT a JDBC bind position — leave those untouched.

### 6.2 The agtype JSON encoding

agtype's textual form is JSON-compatible for the types we need:
- Long → JSON number (no quotes): `933`
- String → JSON string: `"Alice"` (must JSON-escape `"`, `\`, `\n`, etc.)
- Boolean → `true` / `false`
- Long array → JSON array of numbers: `[123, 456]`
- Object array → JSON array of objects: `[{"organizationId": 5, "year": 2010}, ...]`
- Map → JSON object: `{"personId": 933, "firstName": "Alice"}`

**Edge case**: agtype distinguishes `numeric` from integer. For LDBC the values are all `long`; pass without quotes and without a decimal point. AGE will infer integer.

**Edge case**: AGE treats the *bind position*'s type as `agtype`. We bind via JDBC `setString(pos, jsonText)` and cast in the SQL: `cypher(..., ?::agtype)`. The cast is required — without it, JDBC sends `text` and PG complains about no implicit conversion to agtype.

### 6.3 Migration architecture

The current code path:

```
Operation → AgeQueryStore.prepare() → text-substituted SQL → Statement.execute()
```

The new path:

```
Operation → AgeQueryStore.prepareTemplate() → SQL template with ?::agtype placeholders
         → AgeQueryStore.getQueryParamMap() → Map<String, Object> raw values
         → AgeAgtypeJson.mapOf(map) → single agtype-JSON String
         → PreparedStatement (server-prepared, cached per physical connection)
         → setString(i, json) for each ?::agtype placeholder
         → execute()
```

### 6.3.1 Sanity-check the 3-arg form before refactoring

Before changing any code, verify the 3-arg cypher() form works against the live DB on a hand-crafted query. Some AGE 1.6 builds have bugs with parameter binding inside `FROM (...)` subqueries or under `UNION ALL`. Run:

```bash
psql "postgresql://postgres:postgres@localhost:5432/postgres" <<'SQL'
LOAD 'age';
SET search_path = ag_catalog, ldbc_snb, public;
PREPARE p1 (agtype) AS
  SELECT * FROM cypher('ldbc_snb', $$
    MATCH (n:Person {id: $personId}) RETURN n.firstName, n.lastName
  $$, $1) AS (firstName agtype, lastName agtype);
EXECUTE p1('{"personId": 933}'::agtype);
EXECUTE p1('{"personId": 1129}'::agtype);
DEALLOCATE p1;
SQL
```

Expected: both EXECUTE calls return one row each. If they return zero rows or error, the 3-arg form is broken on this build — STOP and report. Do not start the migration. (At that point the only fix is to upgrade AGE or stay on the text-substitution path.)

Also test UNION ALL composition:

```bash
psql "postgresql://postgres:postgres@localhost:5432/postgres" <<'SQL'
LOAD 'age';
SET search_path = ag_catalog, ldbc_snb, public;
PREPARE p2 (agtype, agtype) AS
  SELECT * FROM cypher('ldbc_snb', $$
    MATCH (n:Person {id: $personId}) RETURN n.firstName
  $$, $1) AS (firstName agtype)
  UNION ALL
  SELECT * FROM cypher('ldbc_snb', $$
    MATCH (n:Person {id: $personId}) RETURN n.lastName
  $$, $2) AS (firstName agtype);
EXECUTE p2('{"personId": 933}'::agtype, '{"personId": 933}'::agtype);
DEALLOCATE p2;
SQL
```

Expected: two rows. If UNION ALL with multiple agtype params errors, IC1 cannot be migrated as-is — leave IC1 on the text path and document it.

**Critical design choice**: do NOT delete the old text-substitution path. Instead, run both paths side-by-side with a per-query toggle. Reasons:
- AGE 1.6's 3-arg cypher() has known bugs around UNION ALL and certain WITH chains. Some queries may need to stay on the text path.
- One-query-at-a-time migration with validation between each step is the only way to bisect a regression.
- The toggle lets you ship after migrating, say, 18 of 27 queries — partial wins are valuable.

The toggle: a `Set<String> parameterizedQueryTypes` field on `AgeDbConnectionState`, populated at construction time from a property:

```properties
# driver/validate.properties — append
age_parameterized_queries=Query1,Query5,Query11,ShortQuery1PersonProfile,ShortQuery4MessageContent,...
```

A query type that is NOT in the set takes the legacy text-substitution path. A query type that IS in the set takes the new prepared-statement path.

### 6.4 Files to add and change

#### 6.4.1 `AgeAgtypeJson.java` (NEW)

Path: `age/src/main/java/org/ldbcouncil/snb/impls/workloads/age/AgeAgtypeJson.java`

A small utility for emitting the agtype-JSON map from a `Map<String, Object>`. Use Jackson if it's already a transitive dependency; otherwise hand-roll. Suggested shape:

```java
package org.ldbcouncil.snb.impls.workloads.age;

import java.util.List;
import java.util.Map;

/**
 * Emits agtype-textual JSON for use as a parameter to AGE's 3-argument
 * cypher(graph, query, params) function. The agtype text format is a
 * superset of JSON; we use the JSON subset.
 *
 * The output is bound via JDBC as a String and cast in SQL: ?::agtype.
 */
public final class AgeAgtypeJson {
    private AgeAgtypeJson() {}

    public static String mapOf(Map<String, Object> params) {
        StringBuilder sb = new StringBuilder(64);
        sb.append('{');
        boolean first = true;
        for (Map.Entry<String, Object> e : params.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            appendString(sb, e.getKey());
            sb.append(':');
            appendValue(sb, e.getValue());
        }
        sb.append('}');
        return sb.toString();
    }

    private static void appendValue(StringBuilder sb, Object v) {
        if (v == null) sb.append("null");
        else if (v instanceof Long || v instanceof Integer) sb.append(v.toString());
        else if (v instanceof Boolean) sb.append(((Boolean) v) ? "true" : "false");
        else if (v instanceof String) appendString(sb, (String) v);
        else if (v instanceof List<?>) appendList(sb, (List<?>) v);
        else if (v instanceof Map<?, ?>) appendMap(sb, (Map<?, ?>) v);
        else throw new IllegalArgumentException("Unsupported agtype value: " + v.getClass());
    }

    private static void appendList(StringBuilder sb, List<?> items) {
        sb.append('[');
        boolean first = true;
        for (Object item : items) {
            if (!first) sb.append(',');
            first = false;
            appendValue(sb, item);
        }
        sb.append(']');
    }

    @SuppressWarnings("unchecked")
    private static void appendMap(StringBuilder sb, Map<?, ?> m) {
        sb.append('{');
        boolean first = true;
        for (Map.Entry<?, ?> e : m.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            appendString(sb, e.getKey().toString());
            sb.append(':');
            appendValue(sb, e.getValue());
        }
        sb.append('}');
    }

    private static void appendString(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        sb.append('"');
    }
}
```

#### 6.4.2 `AgeQueryStore.java` (MODIFY)

Add a parallel `prepareTemplate()` method that returns the .sql file content **without substituting** runtime `$paramName` references — only `$graphName` is still substituted (it's a SQL-level interpolation, not a Cypher param). The shape:

```java
/**
 * Returns the SQL template with $graphName substituted but all other $paramName
 * references left intact (they will be bound by AGE via the cypher() 3rd-arg
 * agtype map, not by JDBC bind positions in the SQL).
 *
 * Callers must also invoke getQueryParameterMap(operation) to get the bindings.
 */
public String prepareTemplate(QueryType queryType) {
    String sql = readQueryFile(queryType);   // raw file contents
    return sql.replace("$graphName", graphName);
}

/** Map of Cypher parameter name → JSON-encodable value (Long, String, List<Long>, etc.) */
public Map<String, Object> getQueryParameterMap(Operation<?> operation) {
    // Dispatch by operation type to the existing getQueryNMap() methods.
    // Critical: the values returned here must be RAW (Long, String, List<Long>),
    // NOT pre-escaped Cypher literals. The existing getQueryNMap methods return
    // `Long.toString(...)` and Cypher-escaped strings via AgeConverter — those
    // are wrong for the parameterized path because agtype JSON does its own
    // type-correct encoding.
    //
    // Strategy: introduce parallel methods that return raw values:
    //   getQuery1ParamMap(LdbcQuery1)  →  {personId: 933L, firstName: "Alice"}
    // and keep the existing getQuery1Map for the legacy text-substitution path.
    ...
}
```

The implementer should add `getQueryNParamMap()` siblings for every query that's parameterized. The signatures mirror `getQueryNMap()` but the values are unboxed:

```java
@Override
public Map<String, Object> getQuery1ParamMap(LdbcQuery1 operation) {
    return new ImmutableMap.Builder<String, Object>()
            .put(LdbcQuery1.PERSON_ID, operation.getPersonIdQ1())   // Long, not String
            .put(LdbcQuery1.FIRST_NAME, operation.getFirstName())   // String, no Cypher escaping
            .build();
}
```

Note: only add `getQueryNParamMap` for queries that are *actually* migrated. The set grows over time as the migration progresses.

#### 6.4.3 `AgeListOperationHandler.java` / `AgeSingletonOperationHandler.java` / `AgeUpdateOperationHandler.java` (MODIFY)

Each gets a branch on whether the current operation type is parameterized. Sketch for `AgeListOperationHandler`:

```java
@Override
public void executeOperation(TOperation operation, AgeDbConnectionState state,
                             ResultReporter resultReporter) throws DbException {
    String opName = operation.getClass().getSimpleName();
    boolean parameterized = state.isParameterized(opName);

    try (Connection conn = state.getConnection()) {
        List<TOperationResult> results = new ArrayList<>();
        if (parameterized) {
            String sqlTemplate = getQueryTemplate(state, operation);
            Map<String, Object> bindMap = getQueryParameterMap(state, operation);
            String agtypeJson = AgeAgtypeJson.mapOf(bindMap);
            try (PreparedStatement ps = conn.prepareStatement(sqlTemplate)) {
                int placeholderCount = countPlaceholders(sqlTemplate);
                for (int i = 1; i <= placeholderCount; i++) {
                    ps.setString(i, agtypeJson);
                }
                state.logQuery(opName, sqlTemplate);
                if (ps.execute()) {
                    try (ResultSet rs = ps.getResultSet()) {
                        while (rs.next()) results.add(toResult(rs));
                    }
                }
            }
        } else {
            String sql = getQueryString(state, operation);
            state.logQuery(opName, sql);
            try (Statement stmt = conn.createStatement()) {
                if (stmt.execute(sql)) {
                    try (ResultSet rs = stmt.getResultSet()) {
                        while (rs.next()) results.add(toResult(rs));
                    }
                }
            }
        }
        resultReporter.report(results.size(), results, operation);
    } catch (SQLException e) {
        throw new DbException(e);
    }
}

protected abstract String getQueryTemplate(AgeDbConnectionState state, TOperation operation);
protected abstract Map<String, Object> getQueryParameterMap(AgeDbConnectionState state, TOperation operation);

private static int countPlaceholders(String sql) {
    // Count unescaped '?' outside of $$...$$ Cypher dollar-quote blocks.
    // Safe shortcut: count cypher( occurrences (each emits one ?::agtype param).
    int n = 0;
    int idx = 0;
    while ((idx = sql.indexOf("cypher(", idx)) != -1) { n++; idx += 7; }
    return n;
}
```

The same `parameterized ? prepared : text` branch goes in `AgeSingletonOperationHandler` and `AgeUpdateOperationHandler`. The Update handler additionally keeps its `setAutoCommit(false) / commit / rollback / setAutoCommit(true)` envelope.

**Handler-subclass dispatch**: each operation has a concrete subclass in `AgeDb.java` (e.g., `InteractiveQuery1`, `ShortQuery4MessageContent`, `Update1AddPerson`). Each subclass currently overrides `getQueryString(state, operation)` and delegates to the QueryStore: `state.getQueryStore().getQuery1(operation)`. For the parameterized path, each migrated subclass must additionally override the two new abstract methods:

```java
@Override
protected String getQueryTemplate(AgeDbConnectionState state, LdbcQuery1 operation) {
    return state.getQueryStore().getQuery1Template();   // new method on AgeQueryStore
}

@Override
protected Map<String, Object> getQueryParameterMap(AgeDbConnectionState state, LdbcQuery1 operation) {
    return state.getQueryStore().getQuery1ParamMap(operation);   // new method on AgeQueryStore
}
```

For unmigrated subclasses, supply default implementations on the abstract base class that throw `UnsupportedOperationException` — the legacy text path doesn't call them, and a hard fail catches accidental routing of an unmigrated query through the parameterized path.

**`PreparedStatement` caching across calls**: a per-connection cache. The PostgreSQL JDBC driver (pgjdbc) auto-promotes a `PreparedStatement` to a server-side prepared statement after `prepareThreshold` invocations (default 5). Hikari recycles physical connections, so once warm, the cached plan is reused. Wire it via the JDBC URL — pgjdbc reads connection-level params from URL query string, not Hikari `dataSourceProperties`:

```java
// In AgeDbConnectionState constructor, append to the existing JDBC URL:
String jdbcUrl = "jdbc:postgresql://" + endpoint
    + "?options=-c%20search_path%3Dag_catalog%2Cpublic%20-c%20jit%3Doff"
    + "&prepareThreshold=1"          // promote to server-prepared on first use
    + "&preparedStatementCacheQueries=64"   // cache up to 64 distinct templates per connection
    + "&preparedStatementCacheSizeMiB=10";  // cap at 10 MiB
```

Setting `prepareThreshold=1` skips pgjdbc's "warmup" — the very first call goes to a server-prepared statement. Combined with Hikari keeping connections alive across operations, the *same* parsed plan is reused. This is the entire point of Phase E.

Note: at this point we are NOT using HikariCP's `dataSourceProperties` (`cachePrepStmts`, `prepStmtCacheSize`) — those are MySQL-driver settings. pgjdbc's equivalents go in the URL.

#### 6.4.4 `AgeDbConnectionState.java` (MODIFY)

Add a `parameterizedQueryTypes` field:

```java
private final Set<String> parameterizedQueryTypes;

public AgeDbConnectionState(...) {
    ...
    String csv = properties.getOrDefault("age_parameterized_queries", "");
    this.parameterizedQueryTypes = csv.isEmpty()
        ? Collections.emptySet()
        : new HashSet<>(Arrays.asList(csv.split("\\s*,\\s*")));
    // Validate against known operation names — catches typos early.
}

public boolean isParameterized(String operationSimpleName) {
    // operationSimpleName is e.g. "LdbcQuery1"; the property uses "Query1".
    // Strip the "Ldbc" prefix.
    String stripped = operationSimpleName.startsWith("Ldbc")
        ? operationSimpleName.substring(4)
        : operationSimpleName;
    return parameterizedQueryTypes.contains(stripped);
}
```

Also add the four `addDataSourceProperty` calls to the HikariConfig (see §6.4.3).

#### 6.4.5 The `.sql` files (MODIFY, per-query)

Each migrated query gets one syntactic edit: append `, $1::agtype` to every `cypher(...)` call's argument list, **inside the SELECT but outside the dollar-quoted Cypher block**. Example, IS1 before:

```sql
SELECT * FROM cypher('$graphName', $$
  MATCH (n:Person {id: $personId})-[:IS_LOCATED_IN]->(city:City)
  RETURN n.firstName, n.lastName, n.birthday, n.locationIP, n.browserUsed, city.id, n.gender, n.creationDate
$$) AS (firstName agtype, lastName agtype, ..., creationDate agtype);
```

After (Phase E migration):

```sql
SELECT * FROM cypher('$graphName', $$
  MATCH (n:Person {id: $personId})-[:IS_LOCATED_IN]->(city:City)
  RETURN n.firstName, n.lastName, n.birthday, n.locationIP, n.browserUsed, city.id, n.gender, n.creationDate
$$, ?::agtype) AS (firstName agtype, lastName agtype, ..., creationDate agtype);
```

The `?` is a JDBC bind position. The handler calls `setString(1, agtypeJson)` to bind the agtype map. `$personId` inside the dollar-quoted Cypher block is *Cypher* parameter syntax — leave it as-is, AGE resolves it from the bound map at execution time.

For queries with multiple `cypher(...)` blocks (IC1 has three under UNION ALL), each gets its own `?::agtype` and the handler binds the same agtype-JSON to all of them. The Cypher engine ignores entries in the agtype map that the inner query doesn't reference, so passing the full param map to every cypher() call is safe and simpler than computing a per-block subset:

```sql
SELECT ... FROM cypher('$graphName', $$ ...1-hop... $$, ?::agtype) AS (...)
UNION ALL
SELECT ... FROM cypher('$graphName', $$ ...2-hop... $$, ?::agtype) AS (...)
UNION ALL
SELECT ... FROM cypher('$graphName', $$ ...3-hop... $$, ?::agtype) AS (...)
```

The handler counts `cypher(` occurrences (3 here) and binds the same JSON to positions 1, 2, 3.

### 6.5 Per-query rollout cadence

This is the hard part. The implementer migrates queries one at a time, in the order below. After each query is migrated:

1. Append the query's name to `age_parameterized_queries=` in `driver/validate.properties`.
2. `mvn -q clean package -DskipTests`.
3. `bash scripts/restore-database.sh` (full restore — important).
4. Run the 2K subset.
5. `python3 scripts/diagnose-failures.py` and confirm the only Incorrect ops are still IC13 + IC14 (and no fewer — the previously-correct queries must remain correct).
6. **If correct**, move on to the next query. **If incorrect**, revert that single .sql file's `$1::agtype` edit and remove the entry from `age_parameterized_queries`. Continue with the next.

Suggested order (cheap → expensive in case rollback is needed):

```
1.  ShortQuery1PersonProfile     # smallest, 1 cypher() block, no UNION
2.  ShortQuery2PersonPosts
3.  ShortQuery3PersonFriends
4.  ShortQuery4MessageContent
5.  ShortQuery5MessageCreator
6.  ShortQuery6MessageForum
7.  ShortQuery7MessageReplies
8.  Query5                        # IC5: simple, no UNION
9.  Query11                       # IC11: simple
10. Query7                        # IC7: simple
11. Query8                        # IC8: simple
12. Query2                        # IC2: composite key, range filter
13. Query9                        # IC9: similar to IC2
14. Query10                       # IC10: month math
15. Query12                       # IC12: tag class hierarchy
16. Query6                        # IC6: tag co-occurrence
17. Query4                        # IC4: tag exposure window
18. Query3                        # IC3: country pair window
19. Query1                        # IC1: 3-hop UNION ALL — most complex read
20. Update1AddPerson              # IU1: UNWIND tagIds, studyAt[], workAt[]
21. Update2AddPostLike
22. Update3AddCommentLike
23. Update4AddForum               # UNWIND tagIds
24. Update5AddForumMembership
25. Update6AddPost                # UNWIND tagIds + content escaping
26. Update7AddComment             # UNWIND tagIds + replyToId polymorphism
27. Update8AddFriendship
```

If the implementer hits 3 consecutive query failures during migration, **stop and audit** instead of grinding. There's likely a systemic bug in `AgeAgtypeJson` (escaping) or `countPlaceholders` (miscount).

### 6.6 Edge cases

- **`UNWIND $tagIds`**: the parameter is a `List<Long>`. `AgeAgtypeJson.appendList` emits `[123, 456]`. AGE binds Cypher `$tagIds` to that list and UNWIND iterates over it. Verified by IU1 / IU4 / IU6 / IU7.
- **`UNWIND $studyAt`**: a `List<Map<String, Object>>` where each map is `{organizationId: ..., year: ...}`. Emit as JSON array of objects. The Cypher inside accesses `s.organizationId` — agtype field-access syntax works on bound list elements.
- **Long fields that come from `Date.getTime()`**: pass as plain Long. agtype represents them as integer; the existing date-range B-tree functional indexes still work because the Cypher comparison is `msg.creationDate < $maxDate` where both sides are integer agtype.
- **Strings with double quotes / backslashes / newlines**: `AgeAgtypeJson.appendString` handles JSON escaping. **Test specifically with IU6 (Add Post)** which carries free-text content.
- **Empty content**: Phase E does not change the existing behavior of `getUpdate6SingleMap` to coerce null content → "" (see `AgeQueryStore.java:284`). Preserve that null-coercion in the new `getUpdate6ParamMap`.
- **`replyToId` polymorphism in IU7**: handled in `AgeQueryStore.getUpdate7SingleMap:298`. Replicate in `getUpdate7ParamMap` — pick `replyToPostId` if it's `!= -1`, else `replyToCommentId`.

### 6.7 Phase E done criteria

- [ ] All 27 query types in `age_parameterized_queries` (or all-minus-N if some queries were rolled back; in that case the rolled-back set must be documented in a comment in `driver/validate.properties`).
- [ ] `mvn -q clean package -DskipTests` succeeds.
- [ ] After restore + 2K-subset run at thread_count=1: wall clock ≤ **8 minutes** (combined target across C+D+E). Incorrect set is exactly `{IC13: 96, IC14: 96}`.
- [ ] After restore + 2K-subset run at thread_count=8: wall clock ≤ **2 minutes**. JVM CPU > 200% during the run (verifies parallel use). Incorrect set unchanged.
- [ ] `psql -c "SELECT query, calls, total_exec_time FROM pg_stat_statements ORDER BY calls DESC LIMIT 10"` (if pg_stat_statements is loaded) shows ~30 unique queries, each with hundreds of calls — confirming plan reuse. NOT 2,000 unique queries with one call each.

### 6.8 Rollback per query

```bash
# Revert one .sql file
git checkout -- age/queries/interactive-complex-9.sql
# Remove the entry from age_parameterized_queries in driver/validate.properties
# Rebuild + retest.
```

Rollback per phase:

```bash
git checkout -- age/queries age/src/main/java/org/ldbcouncil/snb/impls/workloads/age age/pom.xml
```

---

## 7. Cumulative validation procedure

After each phase, run this exact procedure. Do not skip steps.

### 7.1 Restore the snapshot

The validation driver mutates the DB via Update operations. Re-running on top of a previous run causes duplicate Comments / Memberships / KNOWS edges and produces false-positive failures. Always restore first.

```bash
CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres" \
  bash /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/scripts/restore-database.sh
```

### 7.2 Run the 2K subset

```bash
cd /Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age
# Confirm validate.properties points to the subset file
grep '^validate_database' driver/validate.properties
# Should be: validate_database=/tmp/ldbc_sf01/validation_params-sf0.1-subset.csv

# Time the run
time java -Xmx8g -cp target/age-1.2.0-SNAPSHOT.jar \
  org.ldbcouncil.snb.driver.Client -P driver/validate.properties \
  2>&1 | tee /tmp/validate-phase-$PHASE.log
```

### 7.3 Diagnose failures

```bash
python3 scripts/diagnose-failures.py \
  /tmp/ldbc_sf01/validation_params-sf0.1-subset-failed-actual.json \
  /tmp/ldbc_sf01/validation_params-sf0.1-subset-failed-expected.json
```

**Pass criterion** (per phase):
- The Per-query diagnosis output shows ONLY `Q13` and `Q14` with non-zero failures.
- No `Q1`–`Q12`, no `IS1`–`IS7`, no `IU1`–`IU8` failures.
- Wall clock target met (per phase: §4.5, §5.5, §6.7).

If a non-IC13/14 query type appears in the failures, **stop and bisect** before continuing.

---

## 8. Self-review checklist (for the implementing agent)

Before declaring the work done, confirm every line below is true. If any is false, the work is incomplete.

**Phase C**:
- [ ] `psql -c "SELECT count(*) FROM pg_indexes WHERE schemaname='ldbc_snb'"` is at least 8 higher than the pre-Phase-C audit count.
- [ ] `EXPLAIN MATCH (p:Person {id: 933}) RETURN p.firstName` shows Index Scan on `idx_person_id` (or `gin_person`).
- [ ] 2K subset wall clock ≤ 22 min.

**Phase D**:
- [ ] `SHOW shared_buffers` returns `4GB`.
- [ ] `SHOW work_mem` returns `64MB`.
- [ ] `SHOW jit` returns `off`.
- [ ] 2K subset wall clock ≤ 15 min (combined C+D).

**Phase E**:
- [ ] `grep -c '?::agtype' age/queries/*.sql` ≥ 27 (one per migrated cypher() call; UNION ALL queries contribute multiple).
- [ ] `grep -rn 'AgeAgtypeJson' age/src` shows usage in all three handler base classes.
- [ ] `grep -n 'prepareThreshold=1' age/src/main/java/org/ldbcouncil/snb/impls/workloads/age/AgeDbConnectionState.java` shows the URL-based pgjdbc config.
- [ ] 2K subset wall clock ≤ 8 min at thread_count=1.
- [ ] 2K subset wall clock ≤ 2 min at thread_count=8.
- [ ] If `pg_stat_statements` is loaded: it shows ~30 unique normalized queries with hundreds of calls each (plan reuse confirmed). If not loaded, skip — installing it requires `shared_preload_libraries` and a restart and is not worth it for a one-shot verification.
- [ ] No new operation types in the Incorrect set — only IC13 (96/96) and IC14 (96/96).

**Final**:
- [ ] `driver/validate.properties` is restored to `validate_database=/tmp/ldbc_sf01/validation_params-sf0.1.csv` and `thread_count=1` for committable defaults. Test-time overrides are documented in a separate `driver/validate-perf.properties` if needed.
- [ ] `mvn -q clean package -DskipTests` succeeds.
- [ ] `git diff age/` is reviewed end-to-end before commit.

---

## 9. Review handoff

When the implementer declares done, the reviewer (Opus 4.7) will verify, in order:

1. **Phase C correctness**: `scripts/create-indexes.sql` contains the §4.3 additions verbatim. Indexes are present in `pg_indexes`. EXPLAIN on a sample query uses the index.
2. **Phase D correctness**: All 14 ALTER SYSTEM SETs are in `postgresql.auto.conf`. SHOW for each tunable returns the target value. No values have unexpected `source = 'default'`.
3. **Phase E correctness**:
   - Every migrated `.sql` file has the `$1::agtype` cast on every `cypher()` call. Spot-check 3 random queries to confirm the rest of the file is byte-identical to pre-Phase-E except for that one addition.
   - `AgeAgtypeJson` correctly escapes a string containing `"` and `\n` (write a small unit test if the agent didn't).
   - The handler branch on `state.isParameterized(...)` is present in all three base classes.
   - The HikariCP props for prepared-statement caching are present.
4. **Validation parity**: Run the 2K subset one more time and confirm the Incorrect set matches pre-change (only IC13 + IC14).
5. **Performance numbers**: confirm the wall-clock targets in §1's table are met. If thread_count=8 was tested, confirm scaling (≥ 3× over thread_count=1).
6. **No regressions in correctness**: the diagnose-failures.py output must show *zero* new failure types.

If review fails, the implementing agent fixes and re-tests before re-handoff.

---

## 10. What this plan does NOT do

- Does not change any query's WHERE / RETURN / ORDER BY / LIMIT clauses. Phase E adds `, $1::agtype` to the cypher() argument list and nothing else.
- Does not implement IC13 / IC14. They remain stubs and will continue to report 96/96 Incorrect after the changes. That is the *correct* behavior — the alternative is hiding a known limitation.
- Does not change agefreighter loading, the AGE OID-fixup logic, the snapshot/restore scripts, or any non-AGE module under `/Users/waleed/repositories/ldbc_snb_interactive_v1_impls/`.
- Does not change `driver/validate.properties` defaults beyond appending `age_parameterized_queries`. thread_count and validate_database stay at committed defaults; perf-test overrides go into a separate file or are applied transiently.
- Does not touch `agefreighter-plan.md` or `perf-improvement-plan.md`. Those describe earlier phases and are historical record.