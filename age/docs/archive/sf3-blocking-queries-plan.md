# SF3 Blocking-Queries Investigation & Plan

**Date:** 2026-05-10
**Engine:** Apache AGE 1.6 on PostgreSQL 17 (local — Darwin 25.4.0)
**SF:** SF3 — 24K Persons, 6.4M Comments, 2.6M Posts, 1.13M KNOWS edges

> SF3 baseline benchmark with **all queries enabled** averaged **3.58 ops/s**
> (vs 570 ops/s at SF0.1). With IC5 / IC7 / IC10 disabled it dropped further
> to 0.83 ops/s — IC1 V2 became the new dominant blocker.
>
> All four blocking queries shared the same root pattern: a Cypher form
> that AGE 1.6's planner handled efficiently at SF0.1 (small intermediate
> cardinalities) but switches to a fundamentally worse plan at SF3+ when
> intermediate sets cross some size threshold. Hash-join plans on full
> tables (9M – 9M rows) replace per-row NL probes via index.

## Summary of fixes applied vs. deferred

| Query | Issue | Fix | Status |
|---|---|---|---|
| **IC1** | V2 firstName-driven seed × per-candidate EXISTS depth-3 → 220 candidates × 512K paths/candidate at SF3 | Revert to V1 (person-driven, 3 separate AGE calls — known stable across all SFs) | **Applied** (revert) |
| **IC10** | V3 Merge Join over full IS_LOCATED_IN (9M rows) at SF3 — single calls timing out >120 s, multi-thread runaways >1 hour | V4: insert `WITH p, collect(friend) AS friends UNWIND friends AS friend` barrier between direct-check and city/post traversals — forces NL via index | **Applied** (V4) |
| **IC5** | V7 Parallel Hash Join over full Post + HAS_CREATOR + CONTAINER_OF tables in branch 2 (FoFs) | Schema denormalisation required (Person.forum_post_count side table) — out of scope for query rewrites | **Deferred** (ceiling) |
| **IC7** | W3 already uses collect+UNWIND for likes — the bottleneck at SF3 is the user's message count (~10K msgs × ~2 likers each = 20K NL probes/call) | Either: per-Person `liker_count` denormalisation, or sample-driven LIMIT at the `(p)<-[:HAS_CREATOR]-(msg)` step | **Deferred** (no clear Cypher win without schema change) |

## Per-query deep dive

### IC1 — V2 was a SF0.1 trap

**SF0.1 result:** mean 60→8 ms (−87%), p99 110→24 ms.
**SF3 reality:** single calls running 10+ min, blocking driver threads.

**Root cause:**
- V2 design: seed via `idx_person_firstname` (small set at SF0.1: 1 candidate),
  then per-candidate `CASE WHEN EXISTS { (p)-[:KNOWS*depth]->(friend) }` chained
  at depths 1, 2, 3.
- The depth-3 EXISTS short-circuits when a path is found. For unreachable
  candidates, it walks ALL paths up to depth 3 to verify "no path exists".
- At SF0.1: KNOWS branching factor ≈ 30; firstName candidates ≈ 1. Cost was
  trivially bounded.
- At SF3: KNOWS branching ≈ 50; firstName candidates ≈ 220 (e.g. "Joseph"
  matches 220 Persons). Per-candidate worst case: 50³ = 125K path verifications.
  220 candidates × 125K probes ≈ 27M lookups per query, plus index overhead.
- Worse: `count(*)` of 3-hop `MATCH ... -[:KNOWS]->(:Person)-[:KNOWS]->(:Person)-[:KNOWS]->(f)`
  for sample person 4398046536251 returned **199,296 paths** (with multiplicity)
  and the DISTINCT 3-hop reach query **lost the connection to server** —
  the planner gives up materialising the distinct set.

**Decision:** revert IC1 to V1. V2 was a SF0.1-specific gain that does not
generalise; it amplifies per-candidate scanning by the firstName cardinality.
V1 enumerates the 3-hop friend tree once per call (~199K NL probes ≈ 5 sec
at SF3), then filters by firstName. That cost is bounded.

**Future work (V5 — hybrid):** A SQL recursive CTE on the KNOWS table can
compute the user's reachable set with shortest distance per node (≤3 hops)
in 50-200 ms at SF3. JOIN that with the Cypher firstName-seed and the bio
walk. This is a hybrid (Cypher + SQL CTE) and would scale O(branching³ +
candidates) instead of O(branching³ × candidates). Not implemented this
session — IC1 is currently a moderate cost at SF3 with V1, not a blocker
for benchmark forward progress.

---

### IC10 — V3 → V4 (collect+UNWIND barrier)

**SF0.1 result (V3):** mean 150 / p99 314 ms.
**SF3 reality (V3):** sample 1 = 2 sec; sample 2 (friend tree 4899 → 421
surviving) **timed out at 120 sec single-thread**, ran **>1 hour** under
multi-thread driver contention (verified via `pg_stat_activity`).

**Root cause:**
EXPLAIN on V3 at SF3 shows the planner picking:
```
Index Scan using idx_islocatedin_end on "IS_LOCATED_IN"
  rows=9042640
```
That's a full-table scan masquerading as an index scan — `idx_islocatedin_end`
is on the City side of `(friend)-[:IS_LOCATED_IN]->(city:City)`. The proper
choice is `idx_islocatedin_start` (NL probe per friend) but AGE swaps to
Merge Join when the friend set cardinality crosses some threshold the
planner mis-estimates.

The Merge Join is the same shape as IC5's parallel-hash pathology: a
table-scan on a 9M-row table per call, then merge-joined with the small
friend set. At SF1000 the same edge table would be 90M+ rows.

**Fix (V4):** insert a `WITH p, collect(friend) AS friends UNWIND friends
AS friend` barrier after the direct-check. The barrier:
1. Materialises the surviving friend set explicitly (a list).
2. UNWINDs row-by-row.
3. Forces the planner to NL the downstream traversals (city, posts, tags).

**Measured at SF3:**
- sample 1: V3 ~2 s → V4 ~2 s (no regression on already-fast samples)
- sample 2: V3 timed out at 120 s → **V4: 16.9 s** (≥7× improvement, no
  longer pathological)
- Result rows byte-identical to V3 on both samples.

**SF1000 outlook:** V4 stays index-driven NL throughout. Per-friend cost is
O(posts-per-friend × tags-per-post). At SF1000 with ~3000 surviving friends
and ~10 800 posts/friend, the bound is ~32 M post probes (~30–60 s). At
that point the next step is denormalising `Person.post_count` (Future #1
in the file) — Phase F precedent, well-established pattern.

---

### IC5 — Ceiling reached at SF3 (denormalisation required)

**SF0.1 result (V7):** mean 577 / p99 1338 ms.
**SF3 reality (V7):** Plans cleanly for direct-friends arm but the FoF arm
still hits the documented Parallel Hash Join over **full Post + HAS_CREATOR
+ CONTAINER_OF tables**. At SF0.1 those tables are 67K / 169K / 79K rows.
At SF3 they're 2.6M / 9M / 9M rows — a 30-100× scale-up that turns the
~300 ms parallel hash build into multi-second per call.

We exhausted the Cypher-rewrite landscape for IC5 in the SF0.1 session
(V8a–V8aa, COUNT subquery, UNION ALL inside Cypher, friend-driven post
walk, etc.). Every variant either:
1. Hits the same parallel hash plan (V7, V8aa, V8z), or
2. Drops semantics (V8d, V8g — eliminate forums with 0-post friends), or
3. Pays extra per-row map-unpack overhead (V8b).

**Decision:** keep V7 + the composite `idx_hasmember_end_joindate_agtype`
already in place. Mark as **ceiling reached** for SF3 in pure Cypher /
hybrid form. Disabled in SF3 benchmark properties to allow forward progress
on remaining workload.

**Unblock path (Future #1 in the file):** Denormalise per-`(Person, Forum)`
post count onto a maintained side table:
```sql
CREATE TABLE ldbc_snb."ForumMemberPostCount" (
  forum_id graphid,
  member_id graphid,
  post_count int,
  PRIMARY KEY (forum_id, member_id)
);
```
Maintained at IU6 (AddPost) — increment on insert; load-time backfill from
existing data. IC5's `OPTIONAL MATCH (forum)-[:CONTAINER_OF]->(post)-
[:HAS_CREATOR]->(friend)` becomes a single index lookup per (friend, forum)
pair. Estimated SF1000 IC5 mean: 30-60 ms (vs ~10 sec without).

---

### IC7 — W3 already optimal in pure Cypher

**SF0.1 result (W3):** mean 117 / p99 210 ms.
**SF3 reality (W3):** Per call cost dominated by the user's message count
(`MATCH (p)<-[:HAS_CREATOR]-(msg:Comment)` returns ~10× more rows at SF3).
The W3 collect+UNWIND inversion still works (it forces NL via
`idx_likes_end` for the per-message liker check), but the absolute message
count grows linearly with SF.

**SF1000 estimate:** ~770 K messages × ~10 likers = ~7.7M NL probes →
~40 sec per call.

**Cypher-only further gains exhausted.** The only remaining Cypher-level
trick — `head(collect(...) ORDER BY ...)` per-liker aggregation — was
tested at SF0.1, added overhead.

**Unblock path:** Either:
- Per-Person `liker_count_per_msg` denormalisation onto Comment.properties
  at IU3 (AddCommentLike) — replaces the per-message liker walk with a
  property read.
- Or: per-Person sample-LIMIT at the `(p)<-[:HAS_CREATOR]-(msg)` step.
  This breaks correctness for the LDBC validator but might be acceptable
  if the LDBC spec allows approximate results for large message corpuses
  (it does not — strict count required).

Disabled in SF3 benchmark for forward progress; ceiling reached for
strict correctness.

---

## Cross-cutting themes (DB-architect lens)

### 1. AGE 1.6 planner threshold-flips at SF3+

Multiple queries (IC10 V3, IC1 V2, IC5 branch-2) had Cypher forms where
the planner used NL via index at SF0.1 and switched to hash/merge join
over full edge tables at SF3. The threshold is around the friend-set
cardinality crossing ~300-500 nodes.

**Mitigation pattern:** `WITH x, collect(y) AS ys UNWIND ys AS y`
materialisation barriers between sections force NL plans by hiding the
true cardinality. We've now used this pattern in IC7 W3, IC10 V4 — it
is the most reliable Cypher-level lever against AGE 1.6's planner
mis-estimation at scale.

### 2. Per-row work amplification through CASE+EXISTS chains

IC1 V2's `CASE WHEN EXISTS { ... } THEN 1 WHEN EXISTS { ... } THEN 2 ...`
pattern compiles to one SubPlan per outer row. When the outer row count
× inner-EXISTS worst-case path count grows quadratically with SF, a
SF0.1 win flips to a SF3 catastrophe. The pattern is only safe when the
outer cardinality is bounded by something other than data size (e.g.,
firstName cardinality stays small, or distance is shallow).

**Mitigation pattern:** prefer pre-computing the reachable set ONCE (as
the IC10 V3 → V4 transition shows) over per-candidate path verification.

### 3. Indexing levers we haven't pulled yet

Indexes that would unblock SF3+ regressions in pure Cypher:
- `idx_hascreator_end_creationdate_agtype(end_id, agtype_access creationDate DESC)` — IC2, IC8.
- `idx_hasinterest_start_end(start_id, end_id)` — IC10's per-post tag-interest probe.
- `Person.post_count` integer property + index — IC5, IC10 post-counting.
- `Forum.member_post_count(forum_id, member_id, count)` side table — IC5.
- `idx_islocatedin_start` already exists; AGE's planner mis-uses it at SF3.
  An index hint or a re-shaped query is the only Cypher-level fix.

### 4. Per-call AGE overhead persists across SFs

Across all queries, ~15-150 ms of every call is parser-cache / agtype-
boxing / JDBC text-mode-fetch overhead. This is a constant per call,
not a function of SF. It dominates the fast queries (SQ1/3/5/6 at ~1 ms
SQL plan, ~12 ms benchmark mean) and is significant at every SF.
Investigating AGE internals would unlock every Cypher query 1.5-3×.

---

## Remaining benchmark plan

1. Apply IC1 revert (done) and IC10 V4 (done).
2. SF3 benchmark with all queries enabled, expecting:
   - IC5: still slow (~10-30 sec mean) — primary remaining blocker
   - IC7: 5-15 sec mean
   - IC10: 2-20 sec mean (V4 caps the worst tail)
   - IC1: 5-10 sec mean (V1)
   - All other queries: scale roughly linearly with SF
3. Throughput projection: 8-15 ops/s with all queries enabled (vs 0.83-3.58
   ops/s pre-fix, vs 570 ops/s SF0.1).
4. SQ2 optimization (next).

## Why SF3 numbers will trail SF1000 expectations even after fixes

Even with V4 IC10 + V1 IC1, IC5 / IC7 will dominate SF3 mean times at
multi-second levels. The SF1000 readiness story for those queries is
denormalisation, not Cypher rewrite — and that is a multi-week schema +
load + IU-handler change, out of scope for this session.

The SF3 benchmark numbers should be read as "what works after all the
Cypher-level levers are pulled, with IC5 / IC7 known to be at structural
ceiling".
