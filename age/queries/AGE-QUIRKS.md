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

## 9. Subclass / reply hierarchies are unrolled to fixed depth

For the same reason as quirk 4 — variable-length paths don't push
predicates and are slow — we hand-unroll `[:REPLY_OF*]` and
`[:IS_SUBCLASS_OF*]` to a fixed depth using chained `OPTIONAL MATCH`
and `coalesce()` to pick the deepest non-null.

**Implications:**
- IS2, IS6 unroll REPLY_OF to depth 8.
- IC12 unrolls IS_SUBCLASS_OF to depth 6.
- These depths exceed the maximum observed in LDBC reference data.
  If a real reply chain were deeper than 8, the query would silently
  miss the post — the SQL has no detection for that case. (Intentional;
  matches the LDBC spec's expected depth.)

## 10. Cypher inside `cypher()` is plan-cached only when parameterised

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
| 9 | Var-length paths slow | IS2, IS6, IC12 (unrolled OPTIONAL MATCH) |
| 10 | Plan caching needs params | every query (parameterised path) |
