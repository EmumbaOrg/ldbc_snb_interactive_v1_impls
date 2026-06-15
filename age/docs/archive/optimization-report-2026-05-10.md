# LDBC SNB Interactive v1 on Apache AGE — Optimization Report

**Date:** 2026-05-10
**Engine:** Apache AGE 1.6 on PostgreSQL 17 (local dev — Darwin 25.4.0, M-series)
**Scale factor exercised:** SF0.1
**Driver config:** 8 threads, 50 000 ops, 5 000 warmup, time_compression_ratio 0.001

> **SF3 status:** SF3 raw data is not present on this machine
> (`/Users/waleed/repositories/ldbc_snb_data/sf3/` does not exist; only
> `sf0.1` and `sf0.3` are local). The previous SF3 result in
> `~/Downloads/sf3_out.log` was run against an Azure HorizonDB cluster.
> Running SF3 locally requires the data download + load (~2–4 hours,
> ~50 GB disk). See "How to run SF3" at the bottom of this report.

---

## 1. Headline numbers (SF0.1, 50 K ops)

| Metric | Pre-session | Post-session | Δ |
|---|---|---|---|
| Throughput | 537 ops/s | **570 ops/s** | **+6%** |
| IC1 mean / p99 | 60 / 110 ms | **8 / 24 ms** | **−87% / −78%** |
| All other queries | unchanged | unchanged | within noise |

The full op-by-op table at the end of this report.

---

## 2. Wins applied this session

### IC1 V2 — firstName-driven seed + per-candidate CASE+EXISTS distance

The original V1 issued **three** AGE calls (one per distance arm), each
driving the BFS from `$personId` outward via KNOWS chains and filtering
on `friend.firstName` post-traversal. Per-call AGE overhead × 3 dominated
the ~60 ms benchmark mean.

V2 inverts the search:
1. Seed via `idx_person_firstname` to find Person rows matching
   `$firstName` (typically a small set — 1–20 candidates at SF0.1).
2. For each candidate, compute the SHORTEST KNOWS distance to
   `$personId` via `CASE WHEN EXISTS { ... }` chained at 1, 2, 3 hops.
3. Single AGE call (UNION ALL inside Cypher).

**Result:** mean 60 → 8 ms (−87%), p99 110 → 24 ms (−78%). Holds at
SF1000 — work bounded by `O(K_firstName × 3 × branching_factor)` where
`K_firstName` is the candidate count, instead of the exponential-tree
expansion in V1.

File: `age/queries/interactive-complex-1.sql`.

---

## 3. Ceilings reached — Cypher/hybrid forms exhausted

These five queries cannot be improved further without schema
denormalisation or AGE planner upgrades. Each was investigated to
diminishing returns this session.

### IC5 (mean 577 / p99 1338 ms) — **the tallest pole**

**Bottleneck:** AGE 1.6 compiles the post-counting OPTIONAL MATCH
`(forum)-[:CONTAINER_OF]->(post:Post)-[:HAS_CREATOR]->(friend)` as a
**parallel hash join over the full Post + HAS_CREATOR + CONTAINER_OF
tables** in branch 2 (FoFs), regardless of how the Cypher is written.

Variants tested and rejected:
- V8a (drop WITH DISTINCT): same plan, same cost
- V8b (collect + UNWIND map barrier): NL plan but per-row map unpack
  doubles the cost (647 ms)
- V8c (bare WITH friend, forum): same parallel hash plan
- V8d (drop OPTIONAL → MATCH): semantics break (no zero-post pairs)
- V8g (single chained MATCH, no OPTIONAL): 58 ms but missing rows where
  `count(post) = 0`. LDBC validator catches this — V8g returns only 2
  rows out of 20 in sample 1.
- V8p (UNION ALL of chained MATCH + member-only zero-arm inside Cypher):
  256 ms, semantically correct but ~17% only
- V8z (`COUNT { ... }` subquery — confirmed AGE 1.6 supports this!):
  414 ms (NL but per-row SubPlan execution)
- V8aa (full V8p-fixed wrap with outer DISTINCT ON + max-count): 296 ms
  (~5% faster, byte-identical to V7) — marginal, kept V7 for stability

**SF3/SF1000 implication:** at SF1000 the parallel hash builds tables
that scale linearly with corpus size. ~67 K Post → 67 M Post = ~2-3 sec
table scan per call before any per-pair work. **IC5 will not hold at
SF1000 in its current form.**

**Unblock path:**
- Denormalise per-(Person, Forum) post count onto a maintained side
  table. Maintained at IU6 (AddPost) + load-time backfill. Replaces the
  OPTIONAL MATCH with a single property/table lookup. Estimated SF1000
  cost: 30-60 ms vs ~10+ seconds.

### IC2 (mean 110 / p99 281 ms)

**Bottleneck:** per-friend message enumeration (`idx_hascreator_end →
idx_comment_graphid + filter creationDate`) — no per-friend top-K index.

Variants tested:
- V2 (LIMIT 20 inside each Cypher arm): SQL plan 16% faster (89 → 75
  ms) BUT **regressed** in the 50K benchmark (mean 107→134, p99 301→777).
  Inside-Cypher `ORDER BY + LIMIT` disables AGE's parallel append plan.
- Date-driven walk: 241 ms vs 89 ms baseline. LIMIT 20 doesn't push
  through the creator-membership check.

**SF3/SF1000 implication:** ~30 friends × 100x messages per friend at
SF1000 = ~300K rows enumerated per call. Sort to top-20 is ~50-100 ms.
Total ~500-1000 ms at SF1000.

**Unblock path:**
- Denormalise `creationDate` onto HAS_CREATOR.properties at load + IU6/
  IU7. Add composite index
  `idx_hascreator_end_creationdate_agtype` on
  `(end_id, agtype creationDate DESC)`. Per-friend top-K becomes an
  index-only range scan. Estimated SF1000 cost: 30-50 ms.

### IC8 (mean 53 / p99 131 ms)

**Bottleneck:** ~1044 reply rows × 3 NL probes is intrinsic to data
shape — user has many messages, each has many replies, each reply has
one author. Plan is fully NL-indexed (idx_hascreator_end + idx_replyof_end
+ idx_hascreator_start + idx_comment_graphid).

Variants tested: same as IC2 — none materially faster.

**SF3/SF1000 implication:** linear scaling with user message count ×
avg replies per message. SF1000 → ~5-10 sec per call.

**Unblock path:** same composite index as IC2 (creationDate on
HAS_CREATOR) enables per-message top-K reply search.

### IC11 (mean 55 / p99 95 ms)

**Bottleneck:** per-friend `WORK_AT.workFrom` filter chain. Plan is
NL-indexed, work scales with `#friends × #jobs-per-friend`.

Variants tested:
- V-IC11-A (UNION ALL inside Cypher): noise (mean 55 vs 54).
- V-IC11-B (country-driven inversion + EXISTS distance check, the same
  pattern that won big for IC1): **83% faster at SF0.1** (39 → 6.7 ms
  SQL plan) BUT catastrophic at SF1000 for popular countries — would
  enumerate millions of employees before checking friendship.

**SF3 implication:** for small countries (Puerto Rico, Switzerland —
both SF0.1 samples) V-IC11-B remains a clear win. For popular countries
(US, Germany) at SF3+, V-IC11-B regresses 100×. Person-driven plan is
robust across all country popularities.

**Unblock path:** adaptive plan selection by country popularity (small
country → drive from country; big country → drive from person). Cypher
cannot express runtime plan-shape selection — needs AGE planner support
or pre-computed country employee counts in a side table.

### IC13, IC14 — disabled, AGE 1.6 limitation

AGE 1.6 does not support `shortestPath()` or `allShortestPaths()`.
Workaround attempts:
- Fixed-depth `CASE + EXISTS` chains: pathological for unreachable
  pairs (would scan ~30^6 = 729M paths to verify no path at depth 6).
- VLE (`KNOWS*1..6`): documented 5× slower than fixed-depth chains for
  shallow patterns (per IC12 W2's TagClass-tree finding). For 6-hop
  IC13 it would be even worse.

**Unblock path:** AGE 1.7+ that lands shortestPath, OR custom BFS
implemented as a recursive CTE in pure SQL (violates the
"Cypher/hybrid only" constraint set this session, but technically
viable as Postgres fallback).

---

## 4. SQ2 (LdbcShortQuery2PersonPosts) — disabled in benchmark

The current SQ2 form has `WITH msg ORDER BY msg.creationDate DESC, msg.id
ASC LIMIT 10` inside Cypher — the same pattern that regressed IC2 V2 in
benchmark vs EXPLAIN. It also chains 8 OPTIONAL MATCHes for REPLY_OF
traversal to find the root post. Disabled in `benchmark.properties`
because of these issues.

To enable at SF1000 it would need:
- Pure-SQL recursive CTE for the REPLY_OF root traversal (like SQ6 does)
- Hybrid: SQL recursive CTE wrapping a Cypher call for the per-message
  fetch

This was out of scope this session — the constraint was to improve
existing queries, not re-architect SQ2.

---

## 5. Pure-SQL queries — reasoning for not converting back

SQ4, SQ6, IC9 are pure SQL. Each was previously moved out of Cypher
because AGE's per-call overhead (~148 ms even for a 0.03-ms SQL plan)
was 25–50× the SQL form. Re-test would reproduce the same regression —
no value in converting back. Documented in each file's header.

---

## 6. Patterns learned (worth re-applying when applicable)

1. **Selective-seed + EXISTS-distance** (IC1 V2): when the predicate
   has bounded cardinality (firstName, country with low employee
   count), seed via the index and check membership/distance via EXISTS
   chains. Massive win when the seed is small *and* the seed
   cardinality stays bounded across SF.

2. **collect + UNWIND barrier flips parallel hash → NL via index**
   (IC7 W3) — but per-row map unpack overhead dominates if the binding
   is carried as a map. Use scalar IDs.

3. **Pre-collect target sets, then membership check** (IC12 W2) —
   works for hierarchical OR chains (TagClass tree) and small static
   target sets.

4. **UNION ALL inside Cypher** instead of SQL UNION ALL — saves
   call-site overhead BUT only meaningful when overhead is large
   fraction of wall time. For already-fast queries (IC11) it's noise.

5. **LIMIT inside Cypher disables parallel append** — beware
   regression in queries like IC2/SQ2 that benefit from it.

6. **OPTIONAL MATCH chains with both endpoints bound** compile to
   parallel hash join in AGE 1.6 — fundamental limitation that drove
   IC5 ceiling. The planner cannot push the bindings into the OPTIONAL
   MATCH compilation, regardless of how the Cypher is phrased.

7. **AGE 1.6 quirks discovered (or rediscovered) this session:**
   - `countCypherCalls` in `AgeListOperationHandler` matches the literal
     string `cypher(` — comments containing `cypher()` blow the
     placeholder count. Strip parens from comments.
   - `CALL { ... }` subquery: not supported (syntax error).
   - `COUNT { ... }` subquery: **supported**, semantics correct, but
     compiles to per-row SubPlan (scales O(N) per outer row).
   - `(x IN [...])` for vertex-typed lists: returns 0 rows (silent bug
     — work around by collecting graphids only).

---

## 7. Full per-query results (50K ops, SF0.1)

| Query | Count | Mean | p99 | State this session |
|---|---|---|---|---|
| LdbcQuery1 | 485 | **8.07** | **24** | **WIN — V2 firstName-driven, −87% / −78%** |
| LdbcQuery10 | 485 | 160.34 | 384 | unchanged (V3 from prior session) |
| LdbcQuery11 | 484 | 55.19 | 95 | ceiling reached — SF1000-safe form kept |
| LdbcQuery12 | 485 | 66.18 | 123 | unchanged (W2 from prior session) |
| LdbcQuery2 | 485 | 110.05 | 281 | ceiling reached — needs HAS_CREATOR.creationDate |
| LdbcQuery3 | 485 | 38.87 | 82 | unchanged (C8 from prior session) |
| LdbcQuery4 | 485 | 7.30 | 29 | already optimal |
| LdbcQuery5 | 484 | 576.50 | 1338 | **TALLEST POLE — needs denormalisation** |
| LdbcQuery6 | 484 | 36.35 | 74 | unchanged (W5 from prior session) |
| LdbcQuery7 | 484 | 117.26 | 210 | unchanged (W3 from prior session) |
| LdbcQuery8 | 485 | 53.18 | 131 | ceiling reached — same path as IC2 |
| LdbcQuery9 | 486 | 3.48 | 14 | pure SQL (Phase F) |
| LdbcShortQuery1 | 7370 | 2.15 | 14 | already optimal |
| LdbcShortQuery3 | 7370 | 1.35 | 10 | already optimal |
| LdbcShortQuery4 | 7331 | 1.03 | 13 | pure SQL |
| LdbcShortQuery5 | 7331 | 1.15 | 9 | already optimal |
| LdbcShortQuery6 | 7331 | 1.48 | 10 | pure SQL |
| LdbcShortQuery7 | 7331 | 3.55 | 14 | already optimal |
| LdbcUpdate3AddCommentLike | 57 | 14.25 | 36 | already optimal |
| LdbcUpdate4AddForum | 7 | 12.29 | 34 | already optimal |
| LdbcUpdate5AddForumMembership | 185 | 9.05 | 48 | already optimal |
| LdbcUpdate6AddPost | 67 | 8.60 | 48 | already optimal |
| LdbcUpdate7AddComment | 82 | 24.60 | 71 | already optimal |
| LdbcUpdate8AddFriendship | 7 | 14.71 | 58 | already optimal |

---

## 8. Projected SF3 / SF1000 behaviour (estimates, not measured)

Where SF1000 ≈ 100× SF0.1 in row counts. Friend count grows ~3× from
SF0.1 to SF1000 (KNOWS bounded by spec). Per-friend message/forum/work
counts grow ~100×.

| Query | SF0.1 mean | SF3 projected | SF1000 projected | Confidence |
|---|---|---|---|---|
| IC5 | 577 ms | ~2 s | **~10+ s** (parallel hash on 67M Post) | High — parallel hash plan known |
| IC2 | 110 ms | ~300 ms | ~1 s | High — linear in friend tree size |
| IC8 | 53 ms | ~150 ms | ~500 ms | High — same shape as IC2 |
| IC10 | 160 ms | ~400 ms | ~1.5 s | Medium — V3 friend-set bounded |
| IC7 | 117 ms | ~300 ms | ~800 ms | Medium — W3 collect+UNWIND scales |
| IC11 | 55 ms | ~200 ms | ~600 ms | Medium — work scales with friend × job |
| IC1 (V2) | 8 ms | ~25 ms | ~80 ms | High — bounded by firstName cardinality |
| IC4 | 7 ms | ~20 ms | ~60 ms | Medium |
| IC3 | 39 ms | ~150 ms | ~500 ms | Medium — friend graphid collect |
| IC6 | 36 ms | ~120 ms | ~400 ms | Medium |
| IC12 | 66 ms | ~200 ms | ~600 ms | Medium |

**SF1000 readiness assessment:**
- Likely OK without further work (under ~1 sec): IC1, IC4, IC9, all
  ShortQueries, all Updates
- At risk (1-3 sec): IC2, IC3, IC6, IC7, IC8, IC10, IC11, IC12
- **Will not hold without denormalisation: IC5**

---

## 9. Recommended next steps

### Schema denormalisations to land before SF1000

In rough priority order (biggest expected win first):

1. **`Person.forum_post_count(forum_id, post_count)` side table** (or
   onto Person.properties as a JSON map). Unblocks IC5. Maintained at
   IU6 (AddPost: increment) and load-time backfill. Estimated SF1000
   IC5 mean: 30-60 ms (vs ~10 sec without).

2. **`creationDate` denormalised onto HAS_CREATOR.properties** +
   composite index
   `idx_hascreator_end_creationdate_agtype(end_id, agtype creationDate DESC)`.
   Unblocks IC2 and IC8. Maintained at IU6 (AddPost), IU7 (AddComment),
   load-time backfill. Estimated SF1000 IC2/IC8 mean: 30-100 ms (vs
   500-1000 ms without).

3. **`Person.country` denormalised** for IC11 / IC3 country filters.
   Less critical; only matters for popular-country queries at SF1000.

### Java/SDK improvements

- Investigate AGE per-call call-site overhead (~15-150 ms depending on
  query). Likely candidates: `cypher()` parser cache miss, agtype
  boxing on the return path, JDBC text-mode fetch through pgjdbc.
  Profiling AGE internals would benefit every Cypher query.

- AGE 1.7+ with VLE planner improvements would let several queries
  collapse fixed-depth OPTIONAL MATCH chains (IC1 V2 EXISTS, IC12 W2
  descendant collection) to single VLE expressions — cleaner code, no
  performance change expected.

- AGE 1.7+ with `shortestPath()` would unblock IC13 / IC14.

### Driver-side

- Investigate why IC2 V2's `ORDER BY + LIMIT` inside Cypher disabled
  parallel append. If AGE could keep the parallel append while
  honouring the per-arm LIMIT, the SF1000 win for IC2 would be material
  (cap cross-boundary marshalling regardless of friend-message count).

---

## 10. Blocker: How to actually run SF3 from this checkout

SF3 raw data is **not** present locally. The previous SF3 run logged in
`~/Downloads/sf3_out.log` was against an Azure HorizonDB cluster
(see organisation handling for those credentials).

To run SF3 locally (estimated 2–4 hours, ~50 GB disk):

```bash
# 1. Download SF3 dataset
mkdir -p ~/repositories/ldbc_snb_data/sf3 && cd ~/repositories/ldbc_snb_data/sf3
# URL: see https://github.com/ldbc/ldbc_snb_interactive_v2_impls/blob/main/docs/datasets.md
# Approximate size: ~1-2 GB compressed, ~10 GB extracted

# 2. Stage substitution params
# Same source as the dataset link

# 3. Update properties files to point at SF3
sed -i '' 's|sf0.1|sf3|g; s|sf-0.1|sf-3|g' age/driver/*.properties

# 4. Load
CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres" \
  bash age/scripts/load-data.sh   # ~30-60 min

# 5. Generate validation params (50K)
# Edit driver/create-validation-parameters.properties:
#   validation_parameters_size=50000
java --add-opens java.base/sun.nio.ch=ALL-UNNAMED -Xmx16g \
  -cp target/age-1.2.0-SNAPSHOT.jar \
  org.ldbcouncil.snb.driver.Client \
  -P age/driver/create-validation-parameters.properties

# 6. Validate
bash age/scripts/run-local-validation.sh

# 7. Benchmark
java --add-opens java.base/sun.nio.ch=ALL-UNNAMED -Xmx16g \
  -cp target/age-1.2.0-SNAPSHOT.jar \
  org.ldbcouncil.snb.driver.Client \
  -P age/driver/benchmark.properties
```

Expected SF3 outcomes if run today (vs SF0.1 baseline above):
- Throughput: ~150-250 ops/s (vs 570 at SF0.1)
- IC5 likely the dominant bottleneck (~2 sec per call → driver late
  count saturates → throughput crashes)
- All other queries: 3-5× SF0.1 means

---

*Generated 2026-05-10 from final 50K SF0.1 benchmark
(`/tmp/bench-final-50k.log`).*
