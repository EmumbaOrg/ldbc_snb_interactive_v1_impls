# AGE Query Authoring & Review Guide

## Persona
Database expert with deep experience in PostgreSQL/AGE and other graph DBs (Neo4j, GraphDB, TigerGraph).

## Target System

- **Deployment**: Azure Horizon DB (PostgreSQL managed service + AGE extension). Local Docker is dev-convenience only — tuning and restart semantics differ.
- **Hardware**: 32 vCPU / 256 GB RAM. Tuning baselines in `age/scripts/postgres-tuning.md` (production column). Don't invent new settings.
- **Managed-service constraints**: `shared_buffers`, `max_connections`, `max_worker_processes`, `max_prepared_transactions` require the Horizon portal + service restart; cannot be set via `ALTER SYSTEM` mid-task.
- **Target scale**: SF100–SF1000. Reject any tactic that helps SF≤10 at the cost of SF100+. Run `EXPLAIN (ANALYZE, BUFFERS)` at SF10/SF100 minimum — at SF0.1 every table fits in `shared_buffers` and hides real cost.

## Implementation Style — Cypher-First, Hybrid Allowed, No Pure SQL

Every query goes through the AGE/Cypher path. Two tiers, in priority:

1. **Cypher-only** — single `cypher(...)` call with no outer SQL logic beyond the mandatory wrapper. Default for simple lookups, updates, and queries the AGE planner handles well.
2. **Hybrid** — Cypher for graph traversal, outer SQL for aggregation, multi-result `UNION ALL`, or complex `ORDER BY`/`LIMIT`. Use when the traversal is naturally Cypher but the remainder is faster in SQL.

**Pure SQL is forbidden.** The main query must always flow through Cypher. If a tactic seems to require eliminating the `cypher()` call, find an index, denorm column, side table, or rewrite that lets Cypher do the traversal instead. IS6 is the only current holdout — tracked for migration, not precedent.

**Scope of the no-direct-read rule**: applies to runtime query files in `age/queries/`. Deploy-time tooling in `age/scripts/` (`denormalize-schema.sql`, load-time backfill, one-off migrations) is exempt — those run once on a known dataset shape and populate side tables explicitly.

Clean up dead columns/tables when pivoting to a different strategy.

## Companion Documents (read first)

| Document | Purpose |
|---|---|
| `README.md` | Strategy, history, denormalization rationale |
| `AGE-QUIRKS.md` | 12 catalogued AGE limitations (datetime, KNOWS direction, predicate pushdown, …) |
| `SCHEMA.md` | Node/edge labels, agtype storage layout, denorm columns, side tables |
| `INDEXES.md` | GIN on agtype, B-tree on edge IDs, functional indexes, composites |

YAML specs in `query-specifications/` are ground truth — follow exactly. For Cypher pattern correctness, defer to `cypher/queries/` (Neo4j authoritative reference).

## Spec Files

| Pattern | Queries | Notes |
|---|---|---|
| `interactive-complex-read-NN.yaml` | IC1–IC12 | |
| `interactive-complex-read-13.yaml` | IC13 | Returns -1 (no shortestPath) |
| `interactive-complex-read-14-v1.yaml` / `-v2.yaml` | IC14 | Returns [] (no allShortestPaths) |
| `interactive-short-read-NN.yaml` | IS1–IS7 | |
| `interactive-update-NN.yaml` | IU1–IU8 | Sourced from `insert-NN.yaml` in ldbc_snb_docs |

Implementations: `interactive-complex-N.sql`, `interactive-short-N.sql`, `interactive-update-N.sql`.

## Review Checklist

1. **Parameters** — every `$paramName` in the spec maps to one in the SQL. Check for typos/missing.

2. **Graph traversal** — MATCH pattern must follow the spec exactly:
   - Hop count (1-hop vs 2-hop friends-of-friends)
   - Node labels (`Post` vs `Comment` — AGE has no polymorphic `Message`)
   - Edge directions (`(post)-[:HAS_CREATOR]->(person)`, not reversed — a reversed traversal returns 0 rows silently; benchmarks won't catch it but LDBC validation will)
   - **KNOWS direction must always be `-[:KNOWS]->` (directed, never undirected).** Undirected `-[:KNOWS]-` forces a full seq-scan on the KNOWS table regardless of seed selectivity (AGE-QUIRKS §11). IU8 stores KNOWS bidirectionally, so directed traversal finds all friends. Applies to IC1/IC2/IC3/IC5/IC6/IC9/IC10/IC11/IS3/IS7.
   - Reuse named variables across MATCH clauses — anonymous `(:Post)` creates a new unbound node; named `(post)` reuses the bound one.

3. **Filters** — exclusive upper bounds use `<` not `<=` ("before date X"). Check all WHERE conditions against the spec.

4. **2-hop dedup** — friends-of-friends queries exclude direct friends and the start person:
   ```cypher
   OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
   WITH DISTINCT friend, direct WHERE direct IS NULL
   ```

5. **Result columns** — YAML `result` defines exact columns and order. Verify RETURN matches.

6. **Sort order** — YAML `sort` defines primary/secondary keys and direction. Outer-SQL string tie-breakers on agtype must use `::text COLLATE "C"` — PG's default `en_US.UTF-8` sorts punctuation after letters; LDBC oracle uses codepoint order (AGE-QUIRKS §14). For queries with an inner `LIMIT` (e.g. IS2), inner `ORDER BY` must use the same tie-breaker direction as the outer one.

7. **Limit** — YAML `limit` matches `LIMIT N` in the SQL.

8. **Aggregation** — `count(DISTINCT ...)` not `count(*)` when the spec says so. AGE agtype aggregates need a cast: `SUM(col::text::bigint)`.

9. **IC7 tie-breaking** — "lowest message ID wins on timestamp ties": `DISTINCT ON (personId)` window ordered `likeCreationDate DESC, commentOrPostId ASC` (innermost).

10. **IC12 tag source** — tags come from the original Post via `(post:Post)-[:HAS_TAG]->(tag)`, never from the reply.

11. **IU cypher() call count** — minimum needed per IU. **IU7 uses three calls** to dodge AGE MVCC bug (issue #1954, see `../AGE-1.6-MVCC-BUG.md`): the `HAS_TAG` UNWIND must run in a separate visibility window after the Comment is committed, and a third call reads the committed Comment's `content` for the `MessageByCreator` INSERT (Cypher-escaped content can't safely substitute into a SQL string literal). Don't merge IU7's three calls. Tier 1/2 splits: IU1=1, IU4=1, IU5=1, IU6=2, IU7=3. (IU1 dropped from 2→1 in Phase B 2026-05-29: PersonPostCount retired, so the second call that seeded it is gone; AddPerson now completes in a single CREATE+UNWIND call. IU4 dropped from 2→1 in Phase A 2026-05-28: ForumSide retired, so the second call that populated it is gone; AddForum now completes in a single CREATE+UNWIND call.)

12. **SF-appropriate tactics**:
    - Avoid materializing full edge sets if SF1000 will OOM; prefer streaming joins.
    - Verify index selectivity at SF100+.
    - When unsure, `EXPLAIN (ANALYZE, BUFFERS)` at SF10/SF100 minimum.
    - If a tactic only helps at SF≤10, reject it.

13. **No parameterized JDBC path** (as of 2026-05-15). `age_parameterized_queries=` is empty in every `driver/*.properties` — every IC/IS/IU flows through `Statement.execute()` with values string-substituted into the SQL by the Java handler before send. Why: AGE's `MATCH (n:Label {prop: $param})` compiles to a runtime function call that can't bind to GIN at plan time (Seq Scan fallback — AGE-QUIRKS §13/§15); plus ~0.5–1 ms per-call overhead. **What to do**: pass parameters via the handler's `getQueryParameterMap`; reference them as `$paramName` in Cypher and outer SQL (both substituted by the same handler pass). **Do not** add a query to `age_parameterized_queries` without re-measuring under `PREPARE/EXECUTE` at the largest target SF — the generic-vs-custom plan decision is cost-estimate-driven, so a query safe at SF3 can flip to Seq Scan at SF100. The `cy`+`pher(` token is now safe in SQL comments (the legacy comment-scan bug fires only on the parameterized branch, which is dead code at runtime — but the trap returns for anyone who re-enables it).

14. **Outer SQL must not JOIN or aggregate against AGE label tables** in runtime query files. Two read patterns *are* permitted:

    **(a) Cypher RETURN of scalar properties** — the natural peer pattern. Every peer implementation (`postgres/`, `duckdb/`, `umbra/`, `cypher/`, `tigergraph/`) reads Person/Forum/HAS_MEMBER properties directly from the canonical structure with zero side tables. Projecting `friend.firstName`, `forum.title`, or `m.joinDate` in a `cypher()` block's RETURN clause — and consuming those columns in outer SQL — is correct and idiomatic. Preferred.

    **(b) Correlated scalar subqueries against an AGE label table** when all three conditions hold: (i) the WHERE clause is GIN-bound via `properties @> '{"id": X}'::agtype`, (ii) the outer query has already been LIMIT'd so the subquery fires at most ~LIMIT times per call, and (iii) the result is a single scalar projection (not used in a JOIN predicate). IS2's author-name fetch is the canonical example of case (b).

    What §14 forbids is `JOIN ldbc_snb."Person"` / `JOIN ldbc_snb."HAS_MEMBER"` in outer SQL where the planner must operate on raw `agtype` columns over a full table without GIN support. (Deploy-time scripts in `age/scripts/` are exempt — see Implementation Style scope above.)

## Known Intentional Deviations — Do Not Flag

| Query | Deviation | Reason |
|---|---|---|
| IC13 | Returns `-1` | No `shortestPath()` |
| IC14 | Returns `[]` | No `allShortestPaths()` |
| All reads | `UNION ALL` Comment + Post branches | No polymorphic `Message` label |
| All dates | Stored/compared as epoch ms (bigint) | No native DateTime type |

## AGE 1.6 Cypher Support

Verified against AGE 1.6 release tags (`PG14/15/16/17 v1.6.0-rc0`) and that version's regression tests — not master. Re-verify on AGE upgrade.

### Supported — rely on these

| Construct | Example |
|---|---|
| `CALL fn(args) YIELD col` (YIELD mandatory) | `MATCH (a) CALL sqrt(64) YIELD sqrt RETURN a, sqrt` |
| PG function returning scalar `agtype` as expression | `WHERE e.year < public.get_year(e.name)` |
| Schema-qualified function call | `public.fn(...)` |
| `UNWIND list_expr AS x` | `UNWIND [1,2,3] AS i` |
| `range(start, end[, step])` | `range(1, 30, 2)` |
| List comprehensions | `[x IN list WHERE pred \| expr]` |
| List slicing | `list[1..4]`, `list[0..]`, `list[..11]` |
| Map projection | `map { .firstName, age: 30, .* }` |
| `EXISTS { pattern }` / `EXISTS { MATCH … RETURN … }` (incl. nested, UNION inside) | `WHERE EXISTS {(a)-[]->(:pet)}` |
| `COUNT { pattern }` | `WHERE COUNT {(a:person)} > 1` |
| Variable-length paths with inline-map *equality* on edges | `-[:edge* {name:"main"}]-` |
| Aggregates | `count, collect, min, max, sum, avg, stDev, stDevP, percentileCont, percentileDisc, agtype_larger, agtype_smaller` |
| List/element accessors | `head, last, tail, size, reverse, range, nodes, relationships, keys, properties, labels, label, type, id, start_id, end_id, startnode, endnode, length` |
| String functions | `substring, replace, split, toLower, toUpper, ltrim/rtrim/trim, left, right, reverse` |
| Math functions | `abs, ceil, floor, round, sign, sqrt, exp, log, sin/cos/tan/asin/acos/atan, degrees, radians, pi, e, rand` |
| Type conversions | `toInteger, toFloat, toBoolean, toString` (+ `…List` variants) |

### NOT Supported — don't propose these

| Construct | Why |
|---|---|
| `reduce(acc = init, x IN list \| expr)` | No symbol, no regression test |
| `collect(x ORDER BY y DESC)` aggregate-input ordering | No variant exists |
| Per-arm `ORDER BY … LIMIT` inside `UNION` | Parser errors; SF10 IC9 Variant-B reproduced "could not find rte for cd" |
| Comparison operators in inline edge property maps (`-[:R {cd < $X}]-`) | Grammar is equality-only — move comparators to post-MATCH `WHERE` |
| `CALL { subquery }` block form | Grammar accepts only `CALL fn` / `CALL ns.fn`; `{ subquery }` only under EXISTS/COUNT |
| Set-returning functions in Cypher expressions | Scalar/void only per AGE docs |
| `EXPLAIN` / `PROFILE` as Cypher statements | Use PG `EXPLAIN (ANALYZE) SELECT * FROM cypher(...)` |
| `USING INDEX` / `USING JOIN ON` / `USING PERIODIC COMMIT` | Not in grammar |
| `apoc.*`, top-K/heap/priority-queue builtins | None |
| `shortestPath()`, `allShortestPaths()` | Stub enum exists, no production/function/test. IC13/IC14 return constants. |

### Structural Performance Limits

Design around these — empirical from IC9 Phase A and Horizon SF10 experiments, not regression-test assertions:

1. **No LIMIT pushdown.** `MATCH … RETURN … ORDER BY x DESC LIMIT N` materializes the full row set before sort. No Cypher rewrite fixes this in 1.6.
2. **Functional B-tree indexes on extracted property values don't bind from Cypher** (AGE #1000). AGE wraps the vertex in `_agtype_build_vertex(...)` before the accessor. Only `gin_<label>` containment via `properties @> '{"id": X}'::agtype` binds reliably.
3. **GIN containment binds only for literal/parameter values** in inline `{prop: X}`. Runtime values from `UNWIND`/`WITH`/function output fall to seq scans (verified: `UNWIND list AS r MATCH (n:Post {id: r.id})` was 5.7s for 10 lookups at SF3). Workaround: do per-row lookup inside a PG function, or pass via `cypher('…', $$ … $$, {id: …}::agtype)`.
4. **Edge-property comparators in MATCH don't bind to composite functional indexes either** (same root cause as #2). IC9 Phase A confirmed the predicate landed as `Filter:`, not `Index Cond:`. Don't propose "add edge property + functional index" as a fix.
5. **Each `cypher(...)` call costs ~10–30 ms overhead.** Splitting work across calls matters at IU/IS scale (IU7's three-call split is the established example).

### Hybrid Patterns (reach for in order)

**A — Seed-MATCH + UDF body** (AGE-docs sanctioned, fastest). When post-seed work is bounded indexed scans against side tables, put it in a `STABLE` PL/pgSQL function returning a single `agtype` list:

```cypher
MATCH (p:Person {id: $personId})       -- GIN binds for runtime $param here
UNWIND public.my_function(p.id) AS r   -- UDF returns list-shaped agtype
RETURN r.field1, r.field2, …
```

Build the agtype via `jsonb_agg(jsonb_build_object(…))::text::ag_catalog.agtype` — the AGE `agtype_build_list(VARIADIC array_agg(…))` form has a "pfree called with invalid pointer" bug.

**B — `UNWIND range(0, N-1) AS i` driving `CALL public.fn(seed, i) YIELD …`.** Works, but slower than A due to N× PG-function overhead + N× index walks. Reserve for cases where each row needs different per-row Cypher work — and remember, `YIELD` runtime values don't bind to GIN.

**C — Multiple Cypher calls in sequence.** Pays per-call overhead but is the only way around per-call MVCC and label-disjoint patterns (IU7, old IS2).

If no pattern is fast enough, the query joins IS6 as a pure-SQL holdout — exception requiring explicit sanction, with the structural reason documented in the query header.

## Cross-Implementation Reference

| Need | Reference | Notes |
|---|---|---|
| Graph traversal, Cypher correctness, pattern shape | `cypher/queries/` | Neo4j authoritative. TigerGraph/GraphDB cross-check only. |
| Denorm, indexes, JOIN/aggregate shape, CTE structure | `postgres/queries/`, `postgres/ddl/schema_constraints.sql`, `duckdb/queries/`, `umbra/queries/` | No graph layer — borrow SQL backbone for outer SQL around `cypher()` |

Do **not** consult `postgres/`/`duckdb/`/`umbra/` for graph-pattern questions. Known bugs to ignore: TigerGraph IC7 picks highest ID on ties; DuckDB IC7 returns multiple rows per liker on timestamp ties.

**Cross-check against AGE's existing tactics first.** Review `age/scripts/denormalize-schema.sql` and `INDEXES.md`. AGE already has side tables (`ForumMemberPostCount`, `MessageByCreator`, `CommentRootPost`), composite indexes, and GIN+functional-B-tree splits that the relational implementations don't. If a relational tactic looks useful, add the denorm column or index in AGE's schema first, then write the hybrid query — don't convert AGE to pure SQL to mimic the relational shape.

## Validation Against LDBC Reference Params

LDBC distributes pre-computed validation parameters for SF0.1–SF10, **generated by the Neo4j Cypher reference**. Canonical ground truth for `mode=validate_database`; prefer over locally-generated files.

- **Download**: <https://datasets.ldbcouncil.org/interactive-v1/validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst> (~195 MB compressed, ~1.6 GB extracted)
- Per project README: *"These were produced using the Neo4j reference implementation."*

After extracting into `age/datasets/`, wire via:

```properties
# age/driver/validate-local.properties
validate_database=…/age/datasets/validation_params-sf3.csv
ldbc.snb.interactive.scale_factor=3
ldbc.snb.interactive.parameters_dir=…/age/datasets/substitution_parameters-sf3/
ldbc.snb.interactive.updates_dir=…/age/datasets/social_network-sf3-CsvComposite-LongDateFormatter/
```

Then `bash age/driver/validate.sh age/driver/validate-local.properties`. A passing SF3 run = byte-identical results to Neo4j-Cypher for every interactive op.

### Caveats

1. **Do NOT regenerate** `validation_params-sf<N>.csv` locally against AGE — that would validate AGE against AGE's prior output, masking regressions.
2. **The framework treats every mismatch as failure**, including LDBC-Cypher-specific quirks (duplicate emissions from `-[:KNOWS]-` undirected over bidirectional storage, `REPLY_OF*0..` path enumeration). Implementations semantically correct per the LDBC spec but producing unique-rather-than-duplicate output still register as "incorrect" — treat as known divergences and document per-query.
3. **IC13/IC14 are intentionally disabled** in LDBC v1 (no `shortestPath`/`allShortestPaths`); their absence from the failure list is expected.
