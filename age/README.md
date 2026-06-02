# Apache AGE — LDBC SNB Interactive v1 Implementation

Reference implementation of the LDBC Social Network Benchmark Interactive workload for
[Apache AGE](https://age.apache.org/) (PostgreSQL graph extension, version 1.6.0+).

## Overview

| Category | Count | Status |
|---|---|---|
| Interactive Complex (IC) | 12 / 14 | ✅ Implemented |
| IC13 / IC14 | 2 / 14 | ⚠️ Degraded (see below) |
| Interactive Short (IS) | 7 / 7 | ✅ Implemented |
| Interactive Update (IU) | 8 / 8 | ✅ Implemented |

### IC13 / IC14 Limitation

Apache AGE does not support `shortestPath()` or `allShortestPaths()`. These two operations are
handled by degraded-but-spec-compliant stubs:

- **IC13**: Always returns `-1` (the LDBC spec sentinel for "no path exists").
- **IC14**: Always returns an empty list.

These operations must be disabled in validation runs (already set in `driver/validate.properties`):
```properties
ldbc.snb.interactive.LdbcQuery13_enable=false
ldbc.snb.interactive.LdbcQuery14_enable=false
```

## Prerequisites

- JDK 11+, Maven 3.6+
- PostgreSQL with Apache AGE 1.6.0+ extension loaded
- Python 3.8+ with `psycopg2-binary` (auto-installed by `load-test-data.sh`)
- `psql` and `pg_dump`/`pg_restore` CLI tools

## Build

```bash
cd ~/repositories/ldbc_snb_interactive_v1_impls

# Build common + AGE modules
mvn install -pl common -am -DskipTests
cd age && mvn clean package -DskipTests

# Artifact: age/target/age-1.2.0-SNAPSHOT.jar
```

## Configuration

All scripts require a `CONNECTION_STRING` environment variable:

```bash
export CONNECTION_STRING="postgresql://user:pass@host:5432/dbname"
```

Edit `driver/validate.properties` and `driver/benchmark.properties` with:
- `age_endpoint` — `host:port/dbname`
- `age_user` / `age_password`
- `age_graph_name` — defaults to `ldbc_snb`
- `ldbc.snb.interactive.parameters_dir` / `updates_dir` — paths to substitution params and update streams

## Data Loading

### Test data (SF0.003 — for validation)

The test data is copied from the `cypher/test-data/` directory (already in the repo) and loaded via a Python script:

```bash
cd age

# Copies cypher/test-data/* into age/test-data/, loads into AGE, creates indexes,
# runs VACUUM ANALYZE, and takes an initial snapshot.
bash scripts/load-test-data.sh
```

This script auto-creates a `.venv` with `psycopg2-binary` on first run.

### Production data (SF0.1+)

One command runs the whole pipeline — preprocess, load, index, snapshot:

```bash
export CONNECTION_STRING="postgresql://user:pass@host:5432/dbname"
cd age
bash scripts/load-data.sh --sf 3     # 0.1, 1, 3, 10, 100, …
```

`load-data.sh` auto-creates a `.venv` with `psycopg2-binary` on first run. LDBC raw data is
expected at `~/repositories/ldbc_snb_data/sf{N}/` (override with `LDBC_DATA_DIR`). Useful flags:
`--skip-preprocess` (reuse converted CSVs), `--workers N` (COPY/GIN parallelism, default 6),
`--index-workers N` (B-tree build parallelism, default 4).

The script runs these steps in order:

**Step 1 — Preprocess** (`scripts/preprocess_ldbc.py --sf N`, skippable). Produces comma-delimited
CSVs under `scripts/converted/sf{N}/{vertices,edges}/` plus the `agefreighter_config.json` that
drives the load (exactly 11 vertex + 15 edge files; the sanity check fails otherwise). Key
transformations: Places split into `City`/`Country`/`Continent` and organisations into
`Company`/`University`; Person `language`→`speaks` and `email` converted to JSON arrays; `KNOWS`
stored **bidirectionally** (A→B and B→A) because queries traverse directed `(p)-[:KNOWS]->(friend)`.

**Step 2 — Load** (`scripts/load-production-data.py --config … --workers N`). Drops/recreates the
graph and streams all vertices then edges via PostgreSQL `COPY`, parallelised across workers with a
load-time `_id_map` for graphid resolution; GIN builds are deferred until all COPYs finish.

> **Why not `agefreighter --source-type csv` directly?**
> agefreighter's `format_kv()` quotes every value, storing all properties as agtype strings —
> `{"id": "933", …}`. Queries use integer literals (`MATCH (p:Person {id: 933})`), and `933 ≠`
> `"933"` under agtype containment, so every MATCH returns 0 rows. `load-production-data.py` uses
> the same COPY protocol but applies two correctness-critical transforms:
> 1. Columns compared without a cast wrapper — `id`, `creationDate`, `joinDate`, plus derived
>    `birthMonth`/`birthDay` (for IC10) — are stored as agtype integers. Others (`birthday`,
>    `length`, `classYear`, `workFrom`) stay strings: their queries already wrap `toInteger()` /
>    `::bigint`. See [`agefreighter-plan.md`](./agefreighter-plan.md) §2.1.
> 2. Empty-string fields are **omitted**, not stored as `""`, so `coalesce(p.content, p.imageFile)`
>    resolves correctly for image vs. text messages (IS2/IS4/IC2/IC7/IC9).

**Step 3 — Indexes** (`scripts/dispatch-indexes.py --sql create-indexes.sql --workers N`). Splits
`create-indexes.sql` by table and builds each group in parallel with per-session
`maintenance_work_mem`. The inventory (full detail in [`queries/INDEXES.md`](./queries/INDEXES.md)):
- **GIN `properties`** on 6 labels only — `Person, Forum, Tag, City, Company, University`. AGE
  compiles map-form `MATCH (n:Label {id:X})` to `properties @> '{"id":X}'` (containment), which
  needs `gin_agtype_ops`.
- **Functional B-trees on `Post`/`Comment`** — `id` and `creationDate`, bound by the WHERE-form
  anchor `MATCH (n) WHERE n.id=X`. These labels are deliberately **not** GIN-indexed: GIN over
  their `properties` tokenizes free-text `content`/`imageFile` into multi-GB indexes (the SF100
  disk blocker).
- **B-trees on edge `start_id`/`end_id`** (15 edge labels × 2) — adjacency for every multi-hop
  pattern — and on each label's `id` graphid.

**Step 3b** applies `denormalize-schema.sql` (now DROP + targeted `ANALYZE` only — no denorm
columns remain post-Milestone-A). **Step 3c** drops the load-time `_id_map`. A full `VACUUM` is
skipped (Step 3b's ANALYZE covers a fresh, dead-tuple-free load).

**Step 5 — Snapshot** (`scripts/snapshot-database.sh`). Required before validation/benchmark runs
because IU operations mutate the graph — see [Snapshot and Restore](#snapshot-and-restore) below.

## Snapshot and Restore

IU operations mutate the graph. Snapshot before the first run and restore before re-runs:

```bash
export CONNECTION_STRING="postgresql://user:pass@host:5432/dbname"

# Before first run (also done automatically by load-test-data.sh)
bash scripts/snapshot-database.sh

# Before each subsequent run
bash scripts/restore-database.sh
```

The restore script handles the AGE-specific OID mismatch that occurs when `pg_restore` creates a
new schema OID — it patches `ag_catalog.ag_graph` and `ag_catalog.ag_label` to match.

> **You MUST restore before every validation re-run.** `validate_database` mode replays
> Update operations against the live DB, so a second run on top of the first creates duplicate
> Comments (`Update7AddComment`), duplicate forum memberships (`Update5`), duplicate KNOWS
> edges (`Update8`), etc. Symptoms include subset queries returning the same row twice
> (e.g., IS2 returning the same `messageId` at positions 0 and 1) and 2-hop friend traversals
> finding extra paths. Always: `restore-database.sh` → run validation → if re-running, restore again.

## Validation

### Local end-to-end (recommended)

```bash
cd age

# First run: load data, generate params, restore, then validate
bash scripts/run-local-validation.sh --load

# Subsequent runs (skip load if data already loaded):
bash scripts/run-local-validation.sh
```

This script:
1. Generates `test-data/validation_params.csv` using the current implementation
2. Restores the snapshot (resets IU mutations from step 1)
3. Runs `validate_database` against the generated params

### Manual

Edit `driver/validate.properties` with your connection details, then:

```bash
cd age
java -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client \
  -P driver/validate.properties
```

## Benchmark

Edit `driver/benchmark.properties` with your connection details and paths, then:

```bash
cd age
java -cp target/age-1.2.0-SNAPSHOT.jar org.ldbcouncil.snb.driver.Client \
  -P driver/benchmark.properties
```

Reload between runs:
```bash
bash scripts/restore-database.sh
```

## Query Correctness Review (AI Agent Instructions)

YAML query specifications are stored in `queries/query-specifications/` — one file per query:

| Pattern | Files | Notes |
|---|---|---|
| `interactive-complex-read-NN.yaml` | IC1–IC14 | IC14 has two variants: `-v1` and `-v2` |
| `interactive-short-read-NN.yaml` | IS1–IS7 | |
| `interactive-update-NN.yaml` | IU1–IU8 | Sourced from `insert-NN.yaml` in ldbc_snb_docs |

The corresponding SQL implementations are in `queries/interactive-complex-N.sql`, `queries/interactive-short-N.sql`, and `queries/interactive-update-N.sql`.

### How to review a query

For each query, read both the YAML spec and the SQL file, then verify:

1. **Parameters** — every `$paramName` in the spec maps to a `$paramName` substitution in the SQL. Check for typos or missing params.

2. **Graph traversal** — the MATCH pattern must follow the spec description exactly. Pay attention to:
   - Hop count (1-hop friends vs 2-hop friends-of-friends)
   - Node types (`Post` vs `Comment` vs generic `Message` — AGE uses separate labels)
   - Edge directions (e.g. `(post)-[:HAS_CREATOR]->(person)` not the reverse)
   - Whether the same node variable is reused across multiple MATCH clauses (anonymous `(:Post)` creates a new node; named `(post)` reuses the previously bound one)

3. **Filters** — date filters use `<` not `<=` for exclusive upper bounds (spec says "before date X"). Check all WHERE conditions against the description.

4. **2-hop deduplication** — queries involving friends-of-friends must exclude direct friends and the start person. The standard pattern is:
   ```cypher
   OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
   WITH DISTINCT friend, direct WHERE direct IS NULL
   ```

5. **Result columns** — the YAML `result` list defines the exact columns and order. Verify the RETURN clause maps to those columns in the same order.

6. **Sort order** — the YAML `sort` list defines primary/secondary sort keys and directions (`asc`/`desc`). The SQL `ORDER BY` must match exactly, including tie-breakers. For queries with inner `LIMIT` (e.g. IS2), the inner `ORDER BY` must use the same tie-breaker as the outer one.

7. **Limit** — the YAML `limit` field must match `LIMIT N` in the SQL.

8. **Aggregation** — where the spec says `count(DISTINCT ...)`, use `count(DISTINCT ...)` not `count(*)`. Cast agtype aggregates: `SUM(col::text::bigint)`.

9. **IC7 tie-breaking** — spec says "return the Message with lowest identifier" when a liker liked multiple messages at the same timestamp. Use `commentOrPostId ASC` as the innermost tie-breaker within a `DISTINCT ON (personId)` window.

10. **IC12 tag source** — tags must come from the original Post, not from the Comment/reply. Pattern: `(post:Post)-[:HAS_TAG]->(tag)` not `(reply)-[:HAS_TAG]->(tag)`.

### Known intentional deviations

| Query | Deviation | Reason |
|---|---|---|
| IC13 | Always returns `-1` | AGE does not support `shortestPath()` |
| IC14 | Always returns empty list | AGE does not support `allShortestPaths()` |
| All | `UNION ALL` of Comment + Post branches | AGE lacks a polymorphic `Message` label; each message type is a separate vertex label |
| All dates | Stored as epoch milliseconds (bigint) | AGE has no native DateTime type; `AgeConverter` converts `java.util.Date` → epoch ms |

Do **not** flag these as bugs.

### Cross-checking against other implementations

The repo contains reference implementations in `cypher/`, `duckdb/`, `tigergraph/`, and `graphdb/` directories. If a semantic question cannot be resolved from the YAML alone, compare against `cypher/` (Neo4j) as the authoritative reference — it is the implementation used to generate LDBC validation params.

## Architecture

```
AgeInteractiveDb (entry point — registers all 29 handlers)
  └── AgeDb (connection setup, 27 inner handler classes)
        ├── AgeDbConnectionState  (JDBC + LOAD 'age' + search_path)
        ├── AgeQueryStore         (loads .sql files, epoch-ms dates, $graphName substitution)
        ├── AgeConverter          (agtype ↔ Java read/write)
        └── operationhandlers/
              ├── AgeListOperationHandler      (IC1-12, IS2/3/7)
              ├── AgeSingletonOperationHandler (IS1/4/5/6)
              ├── AgeUpdateOperationHandler    (IU1-8)
              ├── AgeIC13OperationHandler      (degraded stub)
              └── AgeIC14OperationHandler      (degraded stub)
```

## Thread Safety

The current implementation uses a single JDBC connection synchronized on all handler calls.
For `thread_count > 1`, replace `AgeDbConnectionState` with a HikariCP connection pool
(pool size = `thread_count`) to eliminate lock contention.

## AGE-Specific Technical Notes

### Date representation

All dates are stored and compared as **epoch milliseconds (bigint)**. The `AgeConverter`
converts `java.util.Date` → `Long.toString(date.getTime())`. Queries use numeric comparisons:
```sql
WHERE msg.creationDate >= $startDate AND msg.creationDate < $endDate
```

### Pattern predicates: bare form unsupported, `EXISTS { }` is supported

Apache AGE 1.6.0 does not accept a **bare** pattern expression as a boolean in `WHERE` / `CASE WHEN`:
```cypher
-- NOT supported in AGE:
WHERE NOT (p)-[:KNOWS]-(friend)
CASE WHEN (a)-[:REL]->(b) THEN ...
```
Rewrite these as `OPTIONAL MATCH` + null checks, or as an `EXISTS { MATCH … }` subquery — the
subquery form **is** supported and is how IC10 does its tag-overlap semi-join inline in Cypher.

### `agtype` aggregation

PostgreSQL has no native `sum(agtype)`. Numeric agtype columns are cast before aggregation:
```sql
SUM(postCount::text::bigint)
```

### Graph schema

Organisations are stored as `University` and `Company` nodes (not a generic `Organisation` label).
KNOWS edges are stored bidirectionally (IU8 creates both `p1→p2` and `p2→p1`) because read
queries use directed patterns `(p)-[:KNOWS]->(friend)`.

### Query structure

Each `.sql` file begins with `SET search_path = ag_catalog, public;` followed by one or more
`SELECT * FROM cypher(...)` calls. The `executeTwoPartSql` helper splits at the first `;` to
execute the `SET search_path` preamble separately before the Cypher query.
