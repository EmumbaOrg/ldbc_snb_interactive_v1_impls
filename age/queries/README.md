# AGE queries

SQL/Cypher implementations of the LDBC SNB Interactive workload for Apache AGE
1.6. Each `.sql` file is one or more `SELECT * FROM cypher('$graphName', $$ … $$)`
calls, optionally wrapped in outer SQL for aggregation/order/limit/union.

**Per-query rationale lives in each `.sql` file header** (kept current with the
code). This README is the high-level map; the companion docs are authoritative
for cross-cutting concerns:

| Doc | Scope |
|---|---|
| `CLAUDE.md` | Authoring + review rules, AGE 1.6 Cypher support matrix, structural limits |
| `AGE-QUIRKS.md` | 15 catalogued AGE limitations and their workarounds |
| `INDEXES.md` | Two anchor shapes, the full index inventory |
| `SCHEMA.md` | Node/edge labels, agtype storage |
| `../QUERY-REVIEW.md` | Per-query architectural review verdicts (OK / FIX / WATCH) |

Use `./check-feature.sh '<regex>'` to grep Cypher feature usage across files
(e.g. `':\w*\*'` for variable-length paths, `'OPTIONAL MATCH'`, `'UNION ALL'`).

## Implementation overview

- **Canonical Cypher (Milestone A, 2026-05-30).** Graph traversal stays in
  Cypher; outer SQL only aggregates/orders/limits/unions. There are **no denorm
  columns and no side tables** — they were retired so the benchmark measures
  AGE's true behavior (the project surfaces AGE weaknesses, not masks them).
- **No parameterized JDBC path (2026-05-15).** Every query is non-parameterized;
  the Java handler string-substitutes values as literals before send, so the
  planner sees a literal and binds the GIN/B-tree (AGE-QUIRKS §13/§15). Do not
  re-enable `age_parameterized_queries` without re-measuring under PREPARE/EXECUTE.
- **Two anchor shapes** (INDEXES.md): map-form `{id:X}` → GIN; WHERE-form
  `WHERE n.id=X` → functional B-tree. Person/Forum/Tag/City/Company/University
  use GIN; Post/Comment anchor by id via the B-tree.
- **No polymorphic `Message` label** (AGE-QUIRKS §3): every Comment-or-Post
  pattern is a two-arm `UNION ALL` of separate `cypher()` calls.
- **KNOWS is always directed `-[:KNOWS]->`** (AGE-QUIRKS §11); IU8 stores both
  directions, so directed traversal finds all friends and avoids the
  undirected full-scan pathology.
- **Variable-length `*` paths crash AGE 1.6** (AGE-QUIRKS §9): hierarchies use a
  fixed-depth `OPTIONAL MATCH` ladder; the VLE forms that can't be unrolled are
  disabled/deferred (IS6, IS2 root-post).
- **Dates are epoch-ms bigints** (AGE-QUIRKS §1): all date logic is integer
  comparison; IC10's birthday window uses precomputed `birthMonth`/`birthDay`.

## Notable per-query points (still-true, non-obvious)

- **IC13 / IC14** — no `shortestPath()`/`allShortestPaths()` in AGE 1.6; Java
  handlers return the LDBC sentinel (`-1` / `[]`). Disabled in all configs.
- **IC10** — tag overlap is a Cypher `EXISTS {}` semi-join, counts computed
  inline; ORDER BY/LIMIT in outer SQL (AGE rejects ORDER BY on a RETURN alias,
  §5). Resolved 2026-06-01.
- **IC12** — two Cypher calls: a `d1–d6` `IS_SUBCLASS_OF` ladder yields valid
  tag ids; the main traversal is friends→comments→post-replies→tags with each
  hop in its own `WITH`. Outer SQL does the bigint semi-join.
- **IS2** — Milestone-A placeholder: returns the message's own id for the
  root-post fields (real resolution needs VLE, deferred to Milestone B). Comment
  rows are expected-incorrect in validation.
- **IS6** — migrated to the natural `-[:REPLY_OF*1..]->` VLE Cypher form to
  surface AGE's VLE crash; **disabled** in all configs pending the AGE VLE fix.
  Not a pure-SQL fallback.
- **IU7** — two Cypher calls: Call 1 creates the Comment + edges; Call 2 runs
  the `HAS_TAG` UNWIND in a fresh MVCC visibility window (AGE #1954). The split
  is non-negotiable; do not merge.
- **IU1/IU4/IU6** — single CREATE+UNWIND each. The per-tag `MATCH (t:Tag {id:})`
  inside `UNWIND` is one GIN lookup per tag (bounded <20 per entity in LDBC).
- **IU8** — creates both KNOWS directions in one transaction (see KNOWS rule).
