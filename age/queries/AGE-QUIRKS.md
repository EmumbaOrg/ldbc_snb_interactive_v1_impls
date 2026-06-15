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

## 8. Property MATCH binding depends on the anchor shape

Two compiled shapes, two index needs:

- **Map-form** `MATCH (n {prop: X})` → `properties @> '{"prop": X}'::agtype` →
  served only by a **GIN** (`gin_agtype_ops`); a functional B-tree does not
  support `@>`.
- **WHERE-form** `MATCH (n) WHERE n.prop = X` →
  `agtype_access_operator(VARIADIC ARRAY[properties,'"prop"'::agtype]) = X` →
  served by a **functional B-tree** on that exact expression.

This **corrects** the older absolute claim that a B-tree on extracted values is
"never used" — that holds only for the map-form. The index expression must
byte-match the compiled predicate; the `CAST(agtype_object_field_text(...))`
form matches neither shape and is never picked.

**Implications:**
- Map-form labels (Person, Forum, Tag, City, Company, University) carry a GIN.
- **Post/Comment** anchor by `id` via the WHERE-form and use functional B-trees
  (`idx_{post,comment}_id_agtype`), **not** a GIN — a content-tokenizing GIN on
  them was the SF100 disk blocker. See INDEXES.md.

## 9. Variable-length `*` paths crash AGE 1.6 — use fixed-depth ladders

Any `*` variable-length relationship (`-[:REPLY_OF*1..]->`,
`[:IS_SUBCLASS_OF*]`) drops the AGE 1.6 backend into **recovery mode** — not
merely slow. The untyped-intermediate seq-scan pathology (quirk 4) plus an
"Invalid number of attributes" error through the label tables aborts the
backend and any concurrent run. Predicate pushdown is also absent.

Pure-SQL recursion over AGE label tables is forbidden (CLAUDE.md), so the
canonical-Cypher workarounds are:

**IS_SUBCLASS_OF (IC12):** a fixed-depth `d1–d6 OPTIONAL MATCH` ladder in
Cypher (the LDBC TagClass hierarchy is ≤ 6 levels). Returns the valid tag ids;
outer SQL does the bigint semi-join, aggregation, and sort.

**REPLY_OF (IS6):** migrated to the natural `-[:REPLY_OF*1..]->` VLE form
specifically to **surface** the crash upstream — DISABLED pending the AGE VLE
fix (the before/after experiment; see `project_vle_before_after`). It is not a
SQL fallback.

**REPLY_OF root-post (IS2):** root-post resolution (`REPLY_OF*0..`) is deferred
to Milestone B (VLE). The Milestone-A placeholder returns the message's own id,
so Comment rows are expected-incorrect in validation.

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

## 12. Multi-hop OPTIONAL MATCH chains trigger backward hash join on edge tables

When a Cypher OPTIONAL MATCH spans two or more hops — e.g.
`OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)-[:IS_LOCATED_IN]->(cc:Country)` — the AGE 1.6
planner may invert the traversal direction and build a **full hash table over the destination
table** (Company × IS_LOCATED_IN × Country × WORK_AT_end), then probe it with the candidate
set, rather than driving forward from the bound `f` nodes using `idx_workat_start`.

**What the bad plan looks like (from SF10 EXPLAIN ANALYZE):**
```
Hash Left Join
  Hash Cond: age_id(f) = wa.start_id
  ->  [candidate set: ~61–1344 rows]
  ->  Hash  (rows=143553, Batches=8, Memory=44MB, temp written=10974 pages)
        ->  Seq Scan on "Company" (1575 rows)
              -> Index Scan idx_islocatedin_start (per company)
              -> Memoize idx_country_graphid
        ->  Index Scan idx_workat_end (91 rows per company)
```
The 143,553-row hash (all WORK_AT relationships × company × country) does not fit in
`work_mem` (8 batches, ~87 MB temp spill), adding **~230 ms per hop arm** at SF10.

By contrast, STUDY_AT in the same query correctly uses forward traversal:
```
Nested Loop Left Join (loops = number_of_candidates)
  -> Index Scan idx_studyat_start (1 loop per candidate)
```

**Root cause:** The planner overestimates the candidate set size (estimates 900, actual 61 for
a common firstName). At 900 estimated candidates, the pre-built Company hash looks cheaper than
900 individual `idx_workat_start` lookups. Actual 61 candidates means forward traversal would
be ~7× cheaper.

**Workaround — split into two 1-hop OPTIONAL MATCHes with an intermediate WITH:**
```cypher
-- Instead of:
OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)-[:IS_LOCATED_IN]->(cc:Country)
WITH f, ..., collect(...) AS companies

-- Write:
OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)
WITH f, ..., wa, co
OPTIONAL MATCH (co)-[:IS_LOCATED_IN]->(cc:Country)
WITH f, ..., collect(...) AS companies
```
The intermediate `WITH` binds `(f)` before the first OPTIONAL MATCH and `(co)` before the
second, removing IS_LOCATED_IN × Country from the hash build. The hash either vanishes
entirely (planner switches to `idx_workat_start` nested loop) or shrinks to WORK_AT × Company
only (~30K rows, fits in memory, no temp spill). Measured improvement: **~344 ms at SF10**
(1016 ms → 672 ms) with the WORK_AT split applied to all three IC1 hop arms.

**Affected queries:** IC1 (all 3 hop arms). Any query using a 2-hop `(n)-[e:EDGE]->(x:Label)-[:IS_LOCATED_IN]->(:Country)` OPTIONAL MATCH pattern in Cypher may trigger the same pathology.

## 13. Prepared-statement plan caching is a net loss for AGE Cypher property MATCH (2026-05-15 reversal)

**Earlier guidance in this section claimed the parameterised path was 30-60%
faster on hot queries. That was wrong — measured empirically against SF3 on
2026-05-15, the parameterised path is equal-or-slower for every shape
we ship, and catastrophically slower for several.**

### Why the parameterised path can't bind GIN

`MATCH (n:Label {prop: $param})` compiles to
`properties @> agtype_build_map('prop', agtype_access_operator($1, '"param"'::agtype))`.
The `agtype_access_operator($1, …)` call is a runtime function — PostgreSQL
can't fold it at plan time, so the GIN cost estimate balloons and the
planner falls back to **`Seq Scan` on the label table**.

Whether PostgreSQL sticks with the generic plan (Seq Scan) or re-plans
custom each call (GIN bitmap with literal) depends on which is cheaper
on paper. For shapes where the generic Seq Scan estimate looks "small
enough" (single-node MATCH on a small-to-medium table), PostgreSQL
locks in the generic plan and you eat Seq Scan forever.

### Measured impact at SF3 (PREPARE/EXECUTE repro)

| Shape | Cached plan | Per-call cost |
|---|---|---|
| `MATCH (m:Comment {id:$})` *(SQ4)* | **Seq Scan on Comment (6.4M rows)** | **4,737 ms p50** |
| `MATCH (p:Person {id:$}) ...` *(SQ1, IC2…)* | **Seq Scan on Person (24K rows)** | **~170 ms baseline** |
| `MATCH (t:Tag {name:$})` *(Q6)* | **Seq Scan on Tag (16K rows)** | **24 ms** |
| `MATCH (m:Comment {id:$})-[:HAS_CREATOR]->(p)` *(SQ5)* | Custom plan, gin_comment | 0.48 ms |
| `MATCH (m:Post {id:$})<-[:REPLY_OF]-...` *(SQ7)* | Custom plan, gin_post | 1.05 ms |
| `MATCH (p:Person {id:$1}), (post:Post {id:$2})` *(IU2/3/8)* | Custom plan, both GIN | 0.14 ms |

The bottom three are safe because the edge or multi-anchor join inflates
the generic-plan estimate above the custom-plan cost — PostgreSQL keeps
re-planning. But **even when the cached path uses a custom plan**, the
parameterised wrapper adds an `agtype_access_operator($1, '"key"')`
extraction per execution that the literal path skips:

| Query | Parameterised total | Non-parameterised total | Diff |
|---|---|---|---|
| SQ5 | 1.48 ms | 0.50 ms | non-param wins ~1 ms |
| IU2 | 0.25 ms | 0.22 ms | wash |
| IU8 | 0.15 ms | 0.11 ms | wash |

### Projected SF1000 behaviour

- Tables grow ~313× (Comment 6.4M → 2B, Person 24K → 10M).
- Seq Scan cost grows linearly → minutes-to-hours per call where the
  generic plan locks in.
- GIN bitmap scan grows logarithmically → barely changes (one or two
  extra btree levels).
- The cost gap between generic Seq Scan and custom GIN *widens* at scale,
  so PostgreSQL is *more* likely to stay on custom plans for the
  safe shapes at SF1000. But the dangerous shapes (single-node MATCH
  on a big table) don't auto-recover — they'd just get worse.

### Resolution (durable, repo-wide)

**`age_parameterized_queries=` is empty in every `driver/*.properties` file.**
Every IC/IS/IU op goes through `Statement.execute()` with the value
string-substituted into the SQL by the Java handler before send. The
planner sees a literal, evaluates GIN cost against the known value, and
picks the bitmap-scan path. Per-call savings are ~0.5-1 ms on the safe
shapes and 4,700 ms on SQ4.

Do not add queries back to `age_parameterized_queries` without
PREPARE/EXECUTE re-measurement against the current SF — the planner's
generic-plan threshold is a function of table-size cost estimates that
shift as the dataset grows.

### Side benefit

Empty parameterised list also eliminates the `countCypherCalls()` trap
in `AgeListOperationHandler` (AGENTS.md §13 → see new quirk **§15**
below) — the handler is bypassed entirely. Writing the literal token
`cy` + `pher(` in a SQL comment no longer crashes the query.

**Implications for query authors:**
- Every IC, IS, and IU query is non-parameterised. Parameters arrive
  as a single `Map<String, Object>` built by the Java handler from the
  LDBC driver's input; the handler substitutes them as quoted literals
  into the SQL template before send.
- The Cypher source can still use `$paramName` for AGE's own
  intra-Cypher parameter binding — that's a separate mechanism (the
  third argument of `cypher()`) and works fine. What's gone is the
  prepared-statement plan caching at the PostgreSQL layer.

## 14. Outer-SQL `ORDER BY` on agtype strings needs `COLLATE "C"`

PostgreSQL's default collation on macOS / our Docker image is
`en_US.UTF-8`, which sorts punctuation (`_`, `-`, etc.) **after** letters
under locale rules. The LDBC oracle is generated by Neo4j Cypher, whose
string comparator uses **codepoint order**: `_` (0x5F) sorts between
uppercase (`Z` = 0x5A) and lowercase (`a` = 0x61). For tie-breaker
columns in outer SQL that compare agtype strings, the two orderings
disagree on tags like `Angel_of_Harlem` vs `Angelina_Jolie`:

| Collation | First |
|---|---|
| `en_US.UTF-8` (default) | `Angelina_Jolie` |
| `C` (codepoint, matches LDBC oracle) | `Angel_of_Harlem` |

The difference flips the row that lands at a `LIMIT N` cutoff when there
is a tie on the primary sort key, causing the validator to mark whole
result sets as incorrect.

**Fix:** cast the agtype column to `text` and pin the collation:
```sql
ORDER BY postCount DESC, tagName::text COLLATE "C" ASC
LIMIT 10;
```
Inside Cypher, sort order is determined by AGE's agtype comparator and
this knob doesn't apply — the fix lives in outer SQL only.

**Affected queries:** IC4 (verified, fixed 2026-05-14). Any other outer-SQL
`ORDER BY <agtype-as-text>` with a tie-breaker that may include
non-alphanumeric ASCII is potentially affected; audit IC6, IC12 and IS2
when next touched.

## 15. GIN containment with a runtime parameter falls back to Seq Scan

The deepest reason §13 had to be reversed: AGE 1.6's Cypher property
MATCH compiles to a `properties @> agtype_build_map(key, value)`
predicate against the label table's `gin_<label>` index. PostgreSQL's
GIN bitmap-scan cost estimator can only consult statistics when the
search term is a **literal `agtype` value known at plan time**. When the
search term arrives as `agtype_access_operator($1, '"key"')`, the
estimator has no histogram to consult, the estimated bitmap cost stays
high, and the planner picks the cheaper-looking estimate — which is
`Seq Scan` for tables with low row count or small heap size.

Three concrete failure modes:

1. **Large label table, single-node MATCH** — generic plan locks in
   Seq Scan, per-call cost is "scan most rows × agtype `@>` recheck
   cost." SQ4 at SF3 hits this: 4,737 ms p50 vs 5 ms for the literal
   path.
2. **Medium label table, single-node MATCH** — Seq Scan looks cheap
   (~1,700 cost units for Person at SF3) so generic plan picks Seq
   Scan; baseline ~170 ms per call. Bad at SF1000 where Person scales
   to ~10M rows.
3. **Small label table, single-node MATCH** — Seq Scan estimate is
   competitive with GIN; planner picks Seq Scan. Q6's Tag (16K rows)
   shows ~24 ms baseline; Tag stays small at SF1000 so the cost is
   bounded, but it's still wasted relative to GIN's ~1 ms.

**What protects against this:**
- An edge join after the property MATCH inflates the generic-plan
  estimate enough that PostgreSQL falls back to per-call custom plans
  (which use the literal-substituted GIN bitmap scan). SQ5/SQ7 stay
  fast for this reason.
- Multi-anchor MATCH (e.g. `(person:Person {id:$1}), (post:Post {id:$2})`)
  multiplies the generic-plan cost beyond the custom-plan cost.
  IU2/IU3/IU8 stay fast for this reason.

**The durable workaround** (now in place): force literal substitution
by emptying `age_parameterized_queries` everywhere. See §13 for
measurements and rationale. Any future query that property-MATCHes a
single node and would benefit from plan caching must verify under
`PREPARE/EXECUTE` that the cached plan does *not* Seq Scan — preferably
at SF100 or higher.

**Affected queries** (all now use literal substitution as of 2026-05-15):
SQ4 (catastrophic), Q6 (24 ms tax), SQ1/SQ2/SQ3/Q2/Q4/Q7/Q8/Q10/Q11/Q12
(170 ms tax via Person anchor). SQ5, SQ7, IU2, IU3, IU8 are
structurally safe but excluded too for code-path simplicity (the per-call
parse-savings of the parameterised path don't materialise; see §13).

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
| 8 | MATCH binding by anchor shape (map-form→GIN, WHERE-form→functional B-tree) | Person/Forum/Tag/City/Company/University (GIN); Post/Comment id (B-tree) |
| 9 | Var-length `*` paths crash AGE 1.6 | IC12 (fixed-depth OPTIONAL MATCH ladder); IS6 (VLE form, disabled); IS2 root-post (deferred to Milestone B) |
| 10 | `NOT (p)-[:TYPE]-(n)` negation rejected by parser | IC9 V4 (uses UNION dedup instead) |
| 11 | Undirected traversal disables seed-node index | IC1, IC2, IC3, IC5, IC6, IC9, IC10, IC11, IS3, IS7 (all fixed: use directed `->`, IU8 guarantees symmetry) |
| 12 | Multi-hop OPTIONAL MATCH triggers backward hash join + disk spill | IC1 (WORK_AT 2-hop pattern; fixed by splitting into two 1-hop steps with intermediate WITH) |
| 13 | Prepared-statement plan caching is a net loss for property MATCH | every query (now all non-parameterised) |
| 14 | PG default collation sorts punctuation after letters | IC4 (fixed: `::text COLLATE "C"` in outer SQL ORDER BY tie-breaker) |
| 15 | GIN containment with runtime param → Seq Scan | SQ4, Q6, all Person-anchored ICs (root cause behind §13 reversal) |
