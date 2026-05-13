# AI Agent Query Correctness Instructions for generation or review 

## Persona
You are a professional Database expert who has deep expertise in both relational and graph databases like Apache AGE with postgres, neo4j, graphdb, tigergraph. 


## Target System & Scale

**Target deployment**: Azure Horizon DB — PostgreSQL managed service with the AGE extension. The local Docker container used during development is for convenience only; it is not the target environment. Tuning and restart semantics differ.

**Target hardware**: 32 vCPU / 256 GB RAM tier. Tuning constants (e.g., `shared_buffers`, `work_mem`, parallelism) are documented in `age/scripts/postgres-tuning.md` (production column). Use those values as the baseline; do not invent new settings.

**Managed-service constraints**: `shared_buffers`, `max_connections`, `max_worker_processes`, and `max_prepared_transactions` cannot be set via `ALTER DATABASE` or `ALTER SYSTEM` — they require the Azure Horizon portal and a service restart. Do not assume server-side restart is available mid-task.

**Target scale factors**: SF100–SF1000. This is the range against which all performance decisions must be validated.

- Do **not** optimize for SF0.1, SF1, or SF3. A tactic that reduces latency by 100 ms at SF1 but causes a 10x regression at SF1000 is the wrong trade. If a tactic only helps at low SF, reject it.
- When evaluating query plans, the lowest SF that exposes real cost is typically SF10 or SF100. Run `EXPLAIN (ANALYZE, BUFFERS)` there, not at SF0.1 where every table fits in `shared_buffers`.


## Implementation Style — Cypher-Only, No Hybrid, No Pure SQL

All queries must go through the AGE/Cypher path via `cypher(...)` calls. Only one tier is recognised:

1. **Cypher-only** — one or more `cypher(...)` calls where all graph traversal, filtering, aggregation, and ordering logic lives inside the Cypher block. The only outer SQL permitted is the minimal wrapper (`SELECT … FROM cypher(…)`) and, where necessary, a `UNION ALL` combining the results of multiple `cypher()` calls (e.g., for multi-label patterns — see AGE-QUIRKS §3). Outer `ORDER BY` and `LIMIT` on the combined result set are also permitted.

**Hybrid queries are forbidden.** A hybrid query is any pattern where outer SQL directly accesses AGE's underlying PostgreSQL label tables (e.g., `ldbc_snb."Post"`, `ldbc_snb."Comment"`, `ldbc_snb."Person"`, `ldbc_snb."KNOWS"`, or any other AGE-managed label table) outside of a `cypher()` call — for example, by joining a `cypher()` result set against `ldbc_snb."Post"` to retrieve properties, or by querying `ldbc_snb."HAS_MEMBER"` directly in outer SQL. Such access bypasses the graph query layer and is not allowed.

**Pure SQL is also forbidden.** If a tactic seems to require eliminating the `cypher()` call entirely, treat that as a sign the approach is wrong — find an index, rewrite the Cypher pattern, or restructure the query so all data retrieval goes through `cypher()`.

IS6 is the only current pure-SQL holdout and is tracked for migration to Cypher. Do not cite it as precedent for new pure-SQL or hybrid implementations.


## Instructions

### Companion documents in this folder

Consult these before generating or reviewing any query:

| Document | Purpose |
|---|---|
| `README.md` | Strategy, history, and denormalization rationale — read first for context on why the implementation is structured the way it is |
| `AGE-QUIRKS.md` | 13 catalogued AGE limitations: datetime handling, multi-label absence, variable-length predicate pushdown, KNOWS direction, multi-hop OPTIONAL MATCH backward hash join, and more |
| `SCHEMA.md` | Node/edge labels, agtype storage layout, denorm columns added in iterations 1/2/3, and side tables |
| `INDEXES.md` | GIN on agtype properties, B-tree on edge `start_id`/`end_id`, functional B-tree on extracted values, and composite indexes |

The YAML specifications are the ground truth. Follow them exactly. For implementation strategy (e.g. how to express a pattern in AGE Cypher), consult the reference implementations listed below.

## Spec Files

YAML query specifications are in `query-specifications/` — one file per query:

| Spec file pattern | Queries | Notes |
|---|---|---|
| `interactive-complex-read-NN.yaml` | IC1–IC12 | |
| `interactive-complex-read-13.yaml` | IC13 | AGE returns -1 constant (no shortestPath support) |
| `interactive-complex-read-14-v1.yaml` / `-v2.yaml` | IC14 | AGE returns empty list (no allShortestPaths support) |
| `interactive-short-read-NN.yaml` | IS1–IS7 | |
| `interactive-update-NN.yaml` | IU1–IU8 | Sourced from `insert-NN.yaml` in ldbc_snb_docs repo |

The corresponding AGE SQL implementations are in:
- `interactive-complex-N.sql` (IC1–IC12; no SQL files for IC13/IC14)
- `interactive-short-N.sql` (IS1–IS7)
- `interactive-update-N.sql` (IU1–IU8)

## How to Review a Query

For each query, read both the YAML spec and the SQL file, then verify:

1. **Parameters** — every `$paramName` in the spec maps to a `$paramName` substitution in the SQL. Check for typos or missing params.

2. **Graph traversal** — the MATCH pattern must follow the spec description exactly. Pay attention to:
   - Hop count (1-hop friends vs 2-hop friends-of-friends)
   - Node types (`Post` vs `Comment` vs generic `Message` — AGE uses separate labels for each)
   - Edge directions (e.g. `(post)-[:HAS_CREATOR]->(person)` not the reverse)
   - **KNOWS direction must always be `-[:KNOWS]->` (directed, never undirected).** Undirected `-[:KNOWS]-` forces a full seq-scan on the entire KNOWS edge table regardless of seed-node selectivity (AGE-QUIRKS §11). IU8 stores KNOWS bidirectionally, so directed traversal finds all friends. Applies to IC1, IC2, IC3, IC5, IC6, IC9, IC10, IC11, IS3, IS7.
   - Whether the same node variable is reused across MATCH clauses — anonymous `(:Post)` creates a new unbound node; named `(post)` reuses the previously bound one. Using anonymous nodes where a named variable is required is a common bug.

3. **Filters** — date filters use `<` not `<=` for exclusive upper bounds ("before date X"). Check all WHERE conditions against the spec description.

4. **2-hop deduplication** — queries involving friends-of-friends must exclude direct friends and the start person. The standard AGE pattern is:
   ```cypher
   OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
   WITH DISTINCT friend, direct WHERE direct IS NULL
   ```

5. **Result columns** — the YAML `result` list defines the exact columns and order. Verify the RETURN clause produces those columns in that order.

6. **Sort order** — the YAML `sort` list defines primary/secondary sort keys and directions (`asc`/`desc`). The SQL `ORDER BY` must match exactly, including tie-breakers. For queries with an inner `LIMIT` (e.g. IS2), the inner `ORDER BY` must use the same tie-breaker direction as the outer one.

7. **Limit** — the YAML `limit` field must match `LIMIT N` in the SQL.

8. **Aggregation** — where the spec says `count(DISTINCT ...)`, use `count(DISTINCT ...)` not `count(*)`. AGE agtype aggregates require a cast: `SUM(col::text::bigint)`.

9. **IC7 tie-breaking** — spec says "return the Message with lowest identifier" when a liker liked multiple messages at the same timestamp. Use `commentOrPostId ASC` as the innermost tie-breaker inside a `DISTINCT ON (personId)` window ordered by `likeCreationDate DESC`.

10. **IC12 tag source** — tags must come from the original Post, not from the Comment/reply. Use `(post:Post)-[:HAS_TAG]->(tag)` not `(reply)-[:HAS_TAG]->(tag)`.

11. **IU cypher() call count** — each `interactive-update-N.sql` contains the minimum number of `cypher()` calls needed. Most IUs use exactly one call. **IU7 is the exception: it uses two calls** to avoid an AGE MVCC concurrency bug (AGE issue #1954 — see `../AGE-1.6-MVCC-BUG.md` for full context and mitigation — the `HAS_TAG` UNWIND must run in a separate visibility window after the Comment is committed). Do not merge IU7's two calls back into one. For all other IUs, keep operations inside a single `$$...$$` block using `WITH ... CREATE` chaining.

12. **SF-appropriate tactics** — Reject any tactic that improves SF≤10 latency at the cost of SF100+ performance. Concrete guidance:
    - Avoid materializing the full edge result set if SF1000 will OOM; prefer streaming joins.
    - Verify index selectivity at SF100+, not at SF0.1 where every table fits in `shared_buffers`.
    - When unsure, run `EXPLAIN (ANALYZE, BUFFERS)` at the lowest SF that exposes real cost (typically SF10 or SF100).
    - If a proposed tactic only shows benefit at SF≤10, reject it and look for an approach that scales.

13. **Split multi-hop OPTIONAL MATCH chains involving edge→label→edge patterns.** A 2-hop OPTIONAL MATCH such as `OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)-[:IS_LOCATED_IN]->(cc:Country)` allows the AGE planner to invert the traversal — building a full hash of all Company × IS_LOCATED_IN × Country × WORK_AT rows and probing with the candidate set — rather than driving forward from `f` via `idx_workat_start`. At SF10 this builds a 143K-row hash that exceeds `work_mem` (8 batches, ~87 MB temp spill, +230 ms per hop arm). The fix is to split into two 1-hop OPTIONAL MATCHes with an intermediate `WITH` that binds each node separately:
    ```cypher
    OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)
    WITH f, ..., wa, co
    OPTIONAL MATCH (co)-[:IS_LOCATED_IN]->(cc:Country)
    WITH f, ..., collect(...) AS companies
    ```
    Apply this pattern to any `(n)-[e:EDGE]->(x:Label)-[:IS_LOCATED_IN]->(:GeoNode)` OPTIONAL MATCH. See AGE-QUIRKS §12.

14. **Never write `cypher(` literally in SQL comments for parameterized queries.** The JDBC handler binds one agtype JSON parameter per `cypher(` occurrence found in the SQL via naive `indexOf("cypher(")` — it does NOT strip comments. If a comment contains `cypher()` or `cypher(` literally, the handler will try to bind more parameters than there are `?` placeholders and the query crashes with `column index is out of range: N, number of columns: M`. Write "Cypher" (no parens) or "the Cypher call" in commentary instead. Applies to any query listed in `age_parameterized_queries` in `driver/*-local.properties` — currently IC4, IC6-IC8, IC10-IC12, IS1-IS5, IS7, IU2, IU3, IU5, IU8. Tracked durable fix: strip SQL comments in `countCypherCalls()` in `AgeUpdateOperationHandler` / `AgeSingletonOperationHandler` / `AgeListOperationHandler`.

## Known Intentional Deviations — Do NOT Flag as Bugs

| Query | Deviation | Reason |
|---|---|---|
| IC13 | Always returns `-1` | AGE does not support `shortestPath()` |
| IC14 | Always returns empty list | AGE does not support `allShortestPaths()` |
| All reads | `UNION ALL` of Comment + Post branches | AGE has no polymorphic `Message` label; Post and Comment are separate vertex labels |
| All dates | Stored and compared as epoch milliseconds (bigint) | AGE has no native DateTime type; Java layer converts `java.util.Date` → epoch ms |

## Cross-Implementation Reference — Split by Purpose

When the YAML spec is ambiguous or a query needs performance work, use the correct lookup path below. The two paths serve different purposes — do not conflate them.

### Path A — Graph traversal, Cypher pattern, correctness

Use when the YAML spec is ambiguous, or to validate Cypher semantics and query shape.

| Implementation | Path | Notes |
|---|---|---|
| **Neo4j (Cypher)** | `cypher/queries/` | **Authoritative reference** — generates LDBC validation params; treat as ground truth for Cypher shape |
| TigerGraph | `tigergraph/gsql/` | GSQL cross-check only |
| GraphDB | `graphdb/queries/` | SPARQL cross-check only |

Do **not** consult `postgres/`, `duckdb/`, or `umbra/` for graph-pattern or correctness questions — they have no traversal semantics to borrow.

Known bugs in other implementations (do not use as correctness reference):
- TigerGraph IC7: picks highest message ID on ties (spec requires lowest)
- DuckDB IC7: can return multiple rows per liker when timestamps tie

### Path B — Denormalization, indexes, JOIN/aggregate shape

Use when an AGE query is stuck on SF100+ performance and you need ideas for CTE structure, JOIN order, predicate placement, aggregate strategy, or FK-index choices.

Consult: `postgres/queries/N.sql`, `postgres/ddl/schema_constraints.sql`, `duckdb/queries/N.sql`, and `umbra/queries/N.sql`.

These implementations have no graph layer — what they offer is a SQL backbone that AGE's hybrid queries can mirror in the outer SQL around a `cypher()` call.

**Cross-check against AGE's existing tactics first.** Before adding anything new, review `age/scripts/denormalize-schema.sql` and `age/queries/INDEXES.md`. AGE already has:
- Denorm `graphid` columns (`Post.creator_id`, `Comment.reply_of_id`, etc.)
- Precomputed side tables (`ForumMemberPostCount`, `PersonPostCount`)
- Composite indexes (e.g., `(forum_id, creator_id)`)
- GIN + functional-B-tree splits that `postgres/` and `duckdb/` do not have

If a tactic from a relational implementation looks useful, propose adding the underlying denorm column or index in AGE's schema first, then write the hybrid query that uses it. Do not convert the AGE query to Pure SQL to mimic the relational shape.
