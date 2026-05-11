# AI Agent Query Correctness Instructions for generation or review 

## Persona
You are a professional Database expert who has deep expertise in both relational and graph databases like Apache AGE with postgres, neo4j, graphdb, tigergraph. 


## Instructions

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

11. **IU single-statement rule** — each `interactive-update-N.sql` must contain exactly one `cypher()` call. All operations (CREATE node + edges) go inside a single `$$...$$` block using `WITH ... CREATE` chaining. Do not split into multiple SELECT statements.

12. **Never write `cypher(` literally in SQL comments for parameterized queries.** The JDBC handler binds one agtype JSON parameter per `cypher(` occurrence found in the SQL via naive `indexOf("cypher(")` — it does NOT strip comments. If a comment contains `cypher()` or `cypher(` literally, the handler will try to bind more parameters than there are `?` placeholders and the query crashes with `column index is out of range: N, number of columns: M`. Write "Cypher" (no parens) or "the Cypher call" in commentary instead. Applies to any query listed in `age_parameterized_queries` in `driver/*-local.properties` — currently IC4, IC6-IC8, IC10-IC12, IS1-IS5, IS7, IU2, IU3, IU5, IU8. Tracked durable fix: strip SQL comments in `countCypherCalls()` in `AgeUpdateOperationHandler` / `AgeSingletonOperationHandler` / `AgeListOperationHandler`.

## Known Intentional Deviations — Do NOT Flag as Bugs

| Query | Deviation | Reason |
|---|---|---|
| IC13 | Always returns `-1` | AGE does not support `shortestPath()` |
| IC14 | Always returns empty list | AGE does not support `allShortestPaths()` |
| All reads | `UNION ALL` of Comment + Post branches | AGE has no polymorphic `Message` label; Post and Comment are separate vertex labels |
| All dates | Stored and compared as epoch milliseconds (bigint) | AGE has no native DateTime type; Java layer converts `java.util.Date` → epoch ms |

## Cross-Checking Against Other Implementations

If the YAML spec is ambiguous, compare against the reference implementations in the repo:

| Implementation | Path | Use for |
|---|---|---|
| **Neo4j (Cypher)** | `cypher/queries/` | **Primary reference** — generates LDBC validation params |
| DuckDB | `duckdb/queries/` | SQL-style cross-check |
| TigerGraph | `tigergraph/gsql/` | GSQL cross-check |
| GraphDB | `graphdb/queries/` | SPARQL cross-check |

Always prefer `cypher/` as the authoritative reference. Known bugs in other implementations:
- TigerGraph IC7: picks highest message ID on ties (spec requires lowest)
- DuckDB IC7: can return multiple rows per liker when timestamps tie