# Apache AGE 1.6 — Limitations and Workarounds

This document lists every AGE-specific limitation that shaped the
implementation. For each item: what AGE doesn't do, why we can't ignore it,
and what we did instead. Targeting **AGE 1.6.0 on PostgreSQL 17**.

A reviewer comparing our SQL against the LDBC YAML spec will see patterns
that look unusual relative to a Neo4j implementation. Almost all of them
trace back to one of the items below.

---

## 1. No datetime types or functions

AGE Cypher has **no `datetime()`, no `EXTRACT`, no date arithmetic, no
timezone handling**. Temporal values are stored as epoch-millisecond
`bigint`s and compared as integers.

**Implications:**
- Date range filters (IC2, IC4, IC9) are bare `creationDate < $maxDate`
  integer comparisons.
- IC10's birthday-window check (a 30-day window straddling a month
  boundary) cannot be computed from `birthday` inside Cypher. We
  precompute `birthMonth` and `birthDay` as integer properties at load
  time (see SCHEMA.md) and filter on those.

## 2. No `shortestPath()` or `allShortestPaths()`

These functions exist in the Cypher standard but are not implemented in
AGE 1.6.

**Implications:**
- IC13 (`SingleShortestPath`) and IC14 (`AllShortestPaths`) cannot be
  expressed. Java handlers return the LDBC "no path" sentinel value
  (`-1` for IC13, empty list for IC14). Both queries are disabled in
  validation/benchmark configs. The placeholder SQL files document this
  in their headers.

## 3. No multi-label MATCH (`(:A|B)`)

AGE Cypher does not support label disjunction in MATCH patterns. There
is no way to write a single MATCH that binds to either a Comment or a
Post.

**Implications:**
- Every "Message" pattern in the LDBC spec — IC2, IC3, IC8, IC9, IS2,
  IS4, IS5, IS6, IS7 — is implemented as **`UNION ALL` of two
  `cypher()` calls**, one per concrete label. The outer SQL combines,
  sorts, and limits the result.
- The PostgreSQL planner can pick different join orders per arm, which
  in practice runs *faster* than a hypothetical multi-label MATCH would,
  because each arm uses the per-label GIN/B-tree. So this quirk is
  beneficial in disguise.

## 4. No predicate pushdown into variable-length paths

A pattern like `[:KNOWS*1..2]` enumerates all matching paths and joins
the predicate afterwards. The planner does not push date-range or label
predicates down into the path expansion.

**Implications:**
- We never write `[:KNOWS*1..2]` for the friends-and-FoF traversal.
  Instead we write the 1-hop and 2-hop arms explicitly:
  ```cypher
  MATCH (p)-[:KNOWS]->(friend)              -- 1-hop arm
  ```
  ```cypher
  MATCH (p)-[:KNOWS]->(:Person)-[:KNOWS]->(friend)
  WHERE friend.id <> $personId
  OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
  WITH friend WHERE direct IS NULL          -- 2-hop, excluding direct friends
  ```
- IC1 explicitly enumerates 1, 2, and 3 hops as three separate `cypher()`
  blocks. A `[:KNOWS*1..3]` rewrite was tried and measured 2.6× slower.

## 5. No `ORDER BY` on `RETURN` aliases

In standard Cypher you can `RETURN x AS y ORDER BY y`. In AGE 1.6
that errors with "could not find rte for y". The expression must be
bound in a preceding `WITH`.

**Implications:**
- Queries that compute a derived value and sort by it (IC10's
  `commonInterestScore`, IC4's `postCount`) bind the value via
  `WITH friend, score AS commonInterestScore` *before* `ORDER BY`.

## 6. `UNION` over full node objects materialises slowly

`UNION` over scalar projections (IDs, names) is fine. `UNION` over
whole-node `RETURN p` clauses can hang for many minutes on modest
result sizes.

**Implications:**
- All UNION arms in our queries return *scalar columns*, not nodes. If
  later filtering needs the full node, we either include all required
  scalars in the projection or perform the post-filter in outer SQL.

## 7. agtype is type-strict; numerics must be stored as integers

AGE compares values across types by *type rank* before value:
agtype_string sorts strictly less than agtype_integer regardless of
content. So `MATCH (p:Person {id: 933})` against a graph where
`id` was loaded as `"933"` (string) returns zero rows.

## 8. Property MATCH requires GIN; B-tree on extracted values is ignored

`MATCH (n {prop: X})` compiles to a `properties @> '{...}'::agtype`
containment predicate, which is only supported by GIN indexes with
`gin_agtype_ops`. Functional B-tree indexes on extracted columns are
*never* used by the planner for this pattern.

**Implications:**
- Every node label has a GIN index on `properties`. Without it, every
  property-keyed MATCH degenerates to a sequential scan. See INDEXES.md.

## 9. Subclass / reply hierarchies require alternative traversal strategies

Variable-length paths don't push predicates and are slow (see quirk 4).
For REPLY_OF and IS_SUBCLASS_OF we use two different strategies:

**REPLY_OF (IS2, IS6):** Uses a SQL `WITH RECURSIVE` CTE on the REPLY_OF
edge table directly (depth cap 20). Each step is one indexed lookup on
`idx_replyof_start`. LDBC reply chains are bounded ~8 across all SFs; the
depth-20 cap is a safety margin. This completely sidesteps the Cypher
path-enumeration pathology and the earlier 8-level `OPTIONAL MATCH` ladder
(which caused untyped-intermediate Parallel Append seq-scans — see quirk 4).

**IS_SUBCLASS_OF (IC12):** Uses a SQL `WITH RECURSIVE` CTE on the
`TagClass.subclass_of_id` denorm column (iter-3). PostgreSQL terminates the
recursion naturally when no new rows are produced (the hierarchy is acyclic),
so no explicit depth cap is needed.

Both strategies avoid the variable-length Cypher pathology entirely.

## 10. `NOT (p)-[:REL_TYPE]-(n)` pattern negation with typed relationship is rejected by the parser

AGE 1.6 rejects the standard Cypher negated-pattern predicate `NOT (p)-[:KNOWS]-(f2)`
when the relationship pattern includes an explicit type label. The error is
`syntax error at or near ":"` — the parser fails on the `:` inside `[:KNOWS]`.

The accepted workaround is `OPTIONAL MATCH (p)-[direct:KNOWS]-(f2) ... WITH ... WHERE direct IS NULL`,
which is semantically equivalent but verbose. In practice (IC9 V4) this idiom was tested
and found to scan the full KNOWS table in the 2-hop arm (see quirk §11), so IC9 V4
uses UNION deduplication instead: the 1-hop arm and the 2-hop arm both filter `friend.id <> $personId`,
and `UNION` naturally deduplicates the combined set. See the IC9 V4 header for the
full semantic equivalence argument.

## 11. Undirected `[:REL_TYPE]-` traversal disables index lookup for seed node

When traversing an **undirected** relationship (`-[:KNOWS]-` rather than `-[:KNOWS]->` or
`<-[:KNOWS]-`), AGE 1.6's planner falls back to a sequential scan on the entire edge table,
even when the seed node is pinned by a GIN property predicate. The `idx_knows_start` /
`idx_knows_end` indexes are not used because the planner generates a `JOIN Filter` that
evaluates both directions after a full edge scan rather than probing each direction index
separately.

**Implications:**
- At SF3, the KNOWS edge table has 1.13 M rows. An undirected 2-hop KNOWS traversal
  (as required for the friends-and-FoF query set) takes **4–5 seconds** regardless of
  the seed person — the full table is scanned twice (once per hop).
- Directed traversal (`-[:KNOWS]->`) uses `idx_knows_start` and runs in ~50–130 ms.
  This is **semantically correct** because IU8 stores KNOWS edges bidirectionally: for
  every friendship (p1, p2) it creates both `p1->p2` and `p2->p1` edges. Therefore
  `MATCH (p)-[:KNOWS]->(f)` finds **all** of p's friends via outgoing edges — the same
  set as undirected traversal. Verified at SF3: directed and undirected return identical
  friend counts (e.g. 5226 for personId=32985348853480, 4656 for personId=10995116278566).
- **Affected queries (round 3 fix):** IC9 V4 and IC5 V11 were previously blocked by this
  pathology when using undirected `-[:KNOWS]-`. Both have now been fixed by switching to
  directed `->`. IC9 V4 `all_friends` CTE: 4,900 ms → 56 ms (87x speedup). IC5 V11
  friends CTE: 4,600 ms (undirected) → 231 ms (directed, with OPTIONAL MATCH dedup).
- **Rule:** Always use `-[:KNOWS]->` in Cypher for KNOWS traversal. Undirected is never
  needed since IU8 guarantees both directions are stored. This rule applies to ALL queries
  that traverse KNOWS: IC1, IC2, IC3, IC5, IC6, IC9, IC10, IC11, IS3, IS7, and any new
  query involving friends or FOF. See AGENTS.md rule 4 for the review checklist entry.

## 12. `cypher()` is plan-cached only when parameterised

If we inline parameter values into the Cypher source as text (e.g.
`MATCH (p:Person {id: 933})`), every call is a fresh parse + plan.
Passing parameters as the third argument
(`cypher('graph', $$ MATCH (p:Person {id: $personId}) ... $$, $1)`)
lets the cypher() function cache the plan across calls with the same
shape — a 30–60% improvement on hot queries.

**Implications:**
- Every IC, IS, and IU query is parameterised. Parameters arrive as a
  single agtype JSON object built by the Java handler from the LDBC
  driver's input. IC3 is the only query that has a parameter reference
  in *outer SQL* (`SUM(CASE WHEN country = $countryXName)`) — its
  outer SQL is not prepared-statement-cached, but each inner
  `cypher()` arm still is.

---

## Summary table — quirk → affected queries

| # | Quirk | Queries shaped by it |
|---|---|---|
| 1 | No datetime | IC10 (birthMonth/birthDay precompute) |
| 2 | No shortestPath | IC13, IC14 (placeholder stubs) |
| 3 | No multi-label MATCH | IC2, IC3, IC5, IC6, IC7, IC8, IC9, IC11, IS2, IS4, IS5, IS6, IS7 |
| 4 | No var-length predicate pushdown | IC1, IC3, IC5, IC6, IC9, IC10, IC11 (explicit 1-/2-hop arms) |
| 5 | No ORDER BY on RETURN aliases | IC4, IC10, IC12 (WITH-bound score) |
| 6 | UNION over nodes hangs | every UNION arm projects scalars |
| 7 | agtype type strictness | loader stores numerics as integers |
| 8 | GIN required for MATCH | INDEXES.md (every node label has GIN) |
| 9 | Var-length paths slow | IS2, IS6 (SQL recursive CTE on REPLY_OF); IC12 (SQL recursive CTE on TagClass.subclass_of_id denorm) |
| 10 | `NOT (p)-[:TYPE]-(n)` negation rejected by parser | IC9 V4 (uses UNION dedup instead) |
| 11 | Undirected traversal disables seed-node index | IC1, IC2, IC3, IC5, IC6, IC9, IC10, IC11, IS3, IS7 (all fixed: use directed `->`, IU8 guarantees symmetry) |
| 12 | Plan caching needs params | every query (parameterised path) |
