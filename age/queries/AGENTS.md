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


## Implementation Style — Cypher-First, Hybrid Allowed, No Pure SQL

All queries must go through the AGE/Cypher path. Two tiers are recognised, in priority order:

1. **Cypher-only** — a single `cypher(...)` call with no outer SQL logic beyond the mandatory wrapper. Default for simple lookups, updates, and queries the AGE planner handles well on its own.

2. **Hybrid** — Cypher for graph traversal, outer SQL for aggregation, filtering, multi-result `UNION ALL`, or complex `ORDER BY` / `LIMIT`. Use when the traversal is the natural Cypher shape but the remainder is faster in SQL. Never read the age graph tables directly from SQL. 

**Pure SQL is forbidden.** The main query must always go through Cypher (either pure or as a hybrid). If a tactic seems to require eliminating the `cypher()` call entirely, treat that as a sign the approach is wrong — find an index, denorm column, side table, or query rewrite that lets Cypher do the traversal. Never read the age tables directly from SQL.

IS6 is the only current pure-SQL holdout and is tracked for migration back to Cypher. Do not cite it as precedent for new pure-SQL implementations.

Always cleanup dead or unused columns or tables created by us for optimization when you pivot to a different strategy. 

## Instructions

### Companion documents in this folder

Consult these before generating or reviewing any query:

| Document | Purpose |
|---|---|
| `README.md` | Strategy, history, and denormalization rationale — read first for context on why the implementation is structured the way it is |
| `AGE-QUIRKS.md` | 12 catalogued AGE limitations: datetime handling, multi-label absence, variable-length predicate pushdown, KNOWS direction, and more |
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

13. **Never write `cypher(` literally in SQL comments for parameterized queries.** The JDBC handler binds one agtype JSON parameter per `cypher(` occurrence found in the SQL via naive `indexOf("cypher(")` — it does NOT strip comments. If a comment contains `cypher()` or `cypher(` literally, the handler will try to bind more parameters than there are `?` placeholders and the query crashes with `column index is out of range: N, number of columns: M`. Write "Cypher" (no parens) or "the Cypher call" in commentary instead. Applies to any query listed in `age_parameterized_queries` in `driver/*-local.properties` — currently IC4, IC6-IC8, IC10-IC12, IS1-IS5, IS7, IU2, IU3, IU5, IU8. Tracked durable fix: strip SQL comments in `countCypherCalls()` in `AgeUpdateOperationHandler` / `AgeSingletonOperationHandler` / `AgeListOperationHandler`.

14. A query should never access the AGE tables directly from the outer SQL. Its strictly forbidden. 

## AGE 1.6 Cypher Constructs — Reference for Query Design

This section is the AI agent's lookup for what Cypher constructs AGE 1.6 actually supports, what it doesn't, and which patterns to reach for when the obvious shape doesn't perform. Every claim here is checked against the AGE 1.6 release tags (`PG14/15/16/17 v1.6.0-rc0`) and that version's regression tests (`regress/expected/*.out`) — not master. Re-verify against the actual version if AGE is upgraded.

### Supported constructs you can rely on

| Construct | Example | Test reference |
|---|---|---|
| `CALL fn(args) YIELD col` | `CALL sqrt(64) YIELD sqrt` | `cypher_call.out:60` |
| `CALL` after `MATCH`/`WITH`, chained with `RETURN` (YIELD mandatory) | `MATCH (a) CALL sqrt(64) YIELD sqrt RETURN a, sqrt` | `cypher_call.out:135` (no-YIELD form errors at `:130`) |
| PG function returning scalar `agtype`, called as an expression | `WHERE e.year < public.get_event_year(e.name)` | [`sql_in_cypher.html`](https://age.apache.org/age-manual/master/advanced/sql_in_cypher.html); function defined at `cypher_call.out:39-43` (uses schema `call_stmt_test`, manual example uses `public`) |
| Schema-qualified function call | `call_stmt_test.add_agtype(1,2)` (regression test) or `public.fn(...)` (manual) | `cypher_call.out:72` |
| `UNWIND list_expr AS x` | `UNWIND [1,2,3] AS i` / `WITH n.a AS a UNWIND a AS i` | `cypher_unwind.out:55,68` |
| `range(start, end[, step])` | `RETURN range(0, 10)`, `range(0, 10, 1)`, `range(1, 30, 2)` | `expr.out:7818,7830`; `list_comprehension.out:46` |
| List comprehensions | `[x IN list WHERE pred \| expr]` | `list_comprehension.out:46–94` |
| List slicing | `list[1..4]`, `list[0..]`, `list[..11]` | `list_comprehension.out:58`; `expr.out:375,382` |
| Map projection | `map { .firstName, .lastName, age: 30, .* }` | `map_projection.out:96,103–110` |
| `EXISTS { pattern }` and `EXISTS { MATCH … WHERE … RETURN … }` (incl. nested, `UNION` inside) | `WHERE EXISTS {(a:person)-[]->(:pet)}` | `cypher_subquery.out:41` (pattern), `:63` (MATCH/RETURN), `:111,:129,:155` (UNION inside), `:164–166` (nested) |
| `COUNT { pattern }` | `WHERE COUNT {(a:person)} > 1` | `cypher_subquery.out:323,331,365` |
| Variable-length paths with *inline-map equality* on edges | `MATCH (u:begin)-[:edge* {name:"main edge"}]-(v:end)` | `cypher_vle.out:233` |
| Aggregates | `count, collect, min, max, sum, avg, stDev, stDevP, percentileCont, percentileDisc, agtype_larger, agtype_smaller` | `agtype.c` symbol list |
| List/element accessors | `head`, `last`, `tail`, `size`, `reverse`, `range`, `nodes`, `relationships`, `keys`, `properties`, `labels`, `label`, `type`, `id`, `start_id`, `end_id`, `startnode`, `endnode`, `length` | `agtype.c` symbol list |
| String functions | `substring, replace, split, toLower, toUpper, ltrim, rtrim, trim, left, right, reverse` | `agtype.c` symbol list |
| Math functions | `abs, ceil, floor, round, sign, sqrt, exp, log, sin/cos/tan/asin/acos/atan, degrees, radians, pi, e, rand` | `agtype.c` symbol list |
| Type conversions | `toInteger`, `toFloat`, `toBoolean`, `toString` (each with `…List` variants) | `agtype.c` symbol list |

### Known NOT supported in AGE 1.6 — do not propose these

| Construct | Verified absent |
|---|---|
| `reduce(acc = init, x IN list \| expr)` accumulator | Not in `PG_FUNCTION_INFO_V1` symbol list; zero regression tests |
| `collect(x ORDER BY y DESC)` aggregate-input ordering | No regression test; aggregate has no order-input variant |
| Per-arm `ORDER BY … LIMIT` inside `UNION` | Two paths fail. Parser-level: subquery UNION without RETURN errors at `cypher_subquery.out:146` (`Subquery UNION without returns not yet implemented`). Empirical: our 2026-05-14 Horizon SF10 IC9 Variant-B test errored on per-arm `ORDER BY cd DESC, mid ASC LIMIT 20` with `could not find rte for cd` (`age/results/ic9-cypher-only-horizon-sf10.txt`). Treat per-arm ORDER+LIMIT inside UNION as broken in 1.6. |
| Comparison operators inside inline edge property map (`-[:R {cd < $X}]-`) | Equality-only. Grammar `cypher_gram.y:2114` defines `map_keyval_list` as `property_key_name ':' expr` (no comparator production). Comparators must move to post-MATCH `WHERE` — which means no early rejection during walk. |
| `CALL { subquery }` block form | Verified absent in grammar (`cypher_gram.y:388–480`): `call_stmt` accepts only `CALL expr_func_norm [YIELD …]` or `CALL expr '.' expr [YIELD …]`. The `'{' subquery_stmt '}'` production appears only under `EXISTS` (line 1955) and `COUNT` (line 1974). |
| `SET RETURNING` functions in Cypher expressions | Per `sql_in_cypher.html`: *"Void and Scalar-Value functions only. Set returning functions are not currently supported."* |
| `EXPLAIN` / `PROFILE` as Cypher statements | Use PG `EXPLAIN (ANALYZE) SELECT * FROM cypher(...)` instead |
| `USING INDEX` / `USING JOIN ON` hints | Not exposed |
| `USING PERIODIC COMMIT` | Not in grammar |
| `apoc.*` or any top-K / heap / priority-queue builtin | None |
| `shortestPath()`, `allShortestPaths()` | Codebase has a stub enum `CSP_FINDPATH /* shortestpath, allshortestpaths, dijkstra */` at `src/include/nodes/cypher_nodes.h:30`, but no grammar production, no built-in, no regression test. IC13/IC14 return constants (see deviations table below). |

### Structural performance limits to design around

These limits are empirical — they come from our IC9 Phase A and Horizon SF10
experiments (see `age/results/ic9-explain-*.txt`) plus the grammar/source
behavior in the 1.6 tag, not directly from regression test assertions. Each
is the rule a plan should account for *before* committing to a shape:

1. **No LIMIT pushdown.** `MATCH … RETURN … ORDER BY x DESC LIMIT N` materializes the full row set before the sort. Per-creator scans that yield thousands of rows for top-10 will scan all of them. There is no Cypher rewrite that fixes this in 1.6.
2. **Functional B-tree indexes on extracted property values do NOT bind from Cypher** (AGE issue [#1000](https://github.com/apache/age/issues/1000)). AGE wraps the vertex in `_agtype_build_vertex(...)` before the property accessor, so the indexed expression never matches. Only `gin_<label>` containment lookups via `properties @> '{"id": X}'::agtype` bind reliably.
3. **GIN property containment only binds for *literal or parameter* values in the inline `{prop: X}` form.** Runtime expressions from `UNWIND`, `WITH`, or function output do not bind — they fall to seq scans. Verified empirically: `UNWIND list AS r MATCH (n:Post {id: r.id})` was 5.7s for 10 lookups at SF3. Workaround: do the per-row lookup inside a PG function, or pass the value as a Cypher parameter via `cypher('…', $$ … $$, {id: …}::agtype)`.
4. **Edge-property comparators in MATCH do not bind to composite functional indexes either** (same root cause as #2). The IC9 Phase A experiment (HAS_CREATOR.creationDate composite functional index) confirmed this — the predicate landed as `Filter:`, not `Index Cond:`. Don't propose "add edge property + functional index" as a perf fix.
5. **Cypher call has fixed ~10–30 ms overhead per `cypher(…)` invocation.** Splitting work across multiple `cypher()` calls in one SQL file costs at the IU/IS scale. IU7's two-call split is the established example.

### Recommended hybrid patterns (Cypher + UDF)

When the obvious Cypher shape hits limits #1–#4, reach for these in order:

**Pattern A — Seed-MATCH + UDF body (AGE-docs-sanctioned).** When everything after the seed is bounded indexed scans against side tables that you don't want to express in Cypher (because of limits #1–#4), put it in a `STABLE` PL/pgSQL function returning a single `agtype` list and call it from Cypher:

```cypher
MATCH (p:Person {id: $personId})       -- only place GIN binds for runtime $param
UNWIND public.my_function(p.id) AS r   -- list-returning agtype, UNWIND fans it out
RETURN r.field1, r.field2, …
```

The UDF body does the SQL work against side tables. Construct the agtype list via `jsonb_agg(jsonb_build_object(…))::text::ag_catalog.agtype` — the AGE `agtype_build_list(VARIADIC array_agg(…))` form has a known memory bug ("pfree called with invalid pointer"). Verified: 28 ms total at SF3 for a top-10-per-person lookup that this pattern solves and pure Cypher cannot (would otherwise materialize all messages per person, 200 ms+ at SF3 and seconds at SF1000).

**Pattern B — `UNWIND range(0, N-1) AS i` driving `CALL public.fn(seed, i) YIELD …`.** Available and confirmed working, but tends to be *slower* than Pattern A because of `N×` PG-function call overhead plus `N×` index walks instead of `1×`. Reserve for cases where each row needs different per-row Cypher work after the function call — and even then, runtime values from `YIELD` won't bind to GIN, so the Cypher work has to stay within the function's output structure.

**Pattern C — Multiple Cypher calls in sequence.** Already in use (IU7's create-then-tag-then-content shape; IS2's old Comment+Post branches). Costs the per-call overhead but is the only way to work around per-call MVCC and label-disjoint patterns.

### What to do when no pattern is fast enough

If a query genuinely cannot be expressed in compliant Cypher at acceptable performance (true top-N at scale on a per-entity dimension where side tables have a composite index that Cypher can't use), it joins the pure-SQL holdout list with IS6. Treat that as an exception requiring explicit sanction, not a default — and document the structural reason in the query's header comment so future readers see why Cypher wasn't chosen.

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

---

## Validation against LDBC-official reference params

LDBC distributes pre-computed validation parameters for SF0.1 through SF10, **generated by the Neo4j Cypher reference implementation**. These are the canonical ground-truth files for `mode=validate_database` and should be preferred over any locally-generated `validation_params.csv`.

- **Download URL**: <https://datasets.ldbcouncil.org/interactive-v1/validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst> (~195 MB compressed, ~1.6 GB extracted).
- **Source of truth**: project README §"Implementing the workload": *"We provide validation parameters for SF0.1 to SF10. These were produced using the Neo4j reference implementation."*

### Contents (after extracting into `age/datasets/`)

| File | Size | Use |
|---|---|---|
| `validation_params-sf0.1.csv` | 228 MB | Smoke tests, fast iteration |
| `validation_params-sf0.3.csv` | 294 MB | |
| `validation_params-sf1.csv` | 338 MB | |
| `validation_params-sf3.csv` | 382 MB | Default local validation target (matches our SF3 dataset) |
| `validation_params-sf10.csv` | 416 MB | Horizon DB validation target |

### How to wire validation to these files

```properties
# age/driver/validate-local.properties
validate_database=/Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/datasets/validation_params-sf3.csv
ldbc.snb.interactive.scale_factor=3
ldbc.snb.interactive.parameters_dir=/Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/datasets/substitution_parameters-sf3/
ldbc.snb.interactive.updates_dir=/Users/waleed/repositories/ldbc_snb_interactive_v1_impls/age/datasets/social_network-sf3-CsvComposite-LongDateFormatter/
```

Then `bash age/driver/validate.sh age/driver/validate-local.properties` runs the validator. A passing run on the SF3 file means our AGE implementation produces byte-identical results to Neo4j-Cypher for every interactive operation in the validation sequence.

### Important caveats

1. **Do NOT regenerate `validation_params-sf<N>.csv` locally against AGE** (via `create-validation-parameters` mode) and overwrite the downloaded file. The LDBC-distributed file is the ground truth; a fresh AGE-generated file would only validate AGE against AGE's prior output (drift-prone) and would hide genuine regressions.
2. **The validation framework treats every output mismatch as a failure**, including LDBC-Cypher-specific quirks (e.g. duplicate emissions from `-[:KNOWS]-` undirected over bidirectional storage, `REPLY_OF*0..` path enumeration). If your implementation is semantically correct per the LDBC spec but produces unique-rather-than-duplicate output, those rows still register as "incorrect". Treat them as known divergences; document each one against the relevant query rather than contorting the implementation to reproduce the duplicates.
3. **IC13 and IC14 are intentionally disabled** in the LDBC v1 spec (AGE has no `shortestPath` / `allShortestPaths`); their absence from the failure list is expected.
