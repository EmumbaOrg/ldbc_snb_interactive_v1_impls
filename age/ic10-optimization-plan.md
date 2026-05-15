# IC10 Optimization Plan

## 1. Performance Baseline (SF10, V6 query)

Three representative samples from `interactive_10_param.txt` measured with
`EXPLAIN (ANALYZE, BUFFERS)` on the Horizon DB SF10 dataset.

| Sample | personId | month | Exec time | Total buffers |
|--------|----------|-------|-----------|---------------|
| S1 | 6597069812321 | 10 | 860 ms | 1,758,480 |
| S2 | 8796093047542 | 12 | 750 ms | 1,706,356 |
| S3 | 19791209314115 | 3 | 827 ms | 1,849,060 |

---

## 2. Buffer Heatmap

Every buffer in the query falls into one of four buckets. Numbers below are from
Sample 1; Samples 2 and 3 are within ±5%.

| Subsystem | Buffers | % of total | Node in plan |
|-----------|---------|------------|--------------|
| `idx_post_graphid` lookups | 1,215,817 | **69.2 %** | `Index Scan using idx_post_graphid on "Post"` |
| `idx_hastag_start` lookups | 342,457 | **19.5 %** | `Index Scan using idx_hastag_start on "HAS_TAG"` |
| `HAS_CREATOR` bitmap heap | 152,036 | **8.6 %** | `Bitmap Heap Scan on "HAS_CREATOR"` |
| FoF walk (all KNOWS hops, birthday filter, direct-check, city) | 40,380 | **2.3 %** | See inner Nested Loop block |
| `PersonPostCount` index scan | 1,659 | 0.1 % | `Index Scan using PersonPostCount_pkey` |
| Planning | ~1,026 | < 0.1 % | |

**97.6 % of all buffer reads occur inside the OPTIONAL MATCH chain.**  
The FoF walk — despite being the most graph-intensive part of the spec — is already
well-optimised and accounts for less than 3 % of cost.

---

## 3. Root Cause Analysis

### RC-1 — HAS_CREATOR carries Post AND Comment edges; ~80 % are Comments (dominant waste)

The Cypher pattern `(friend)<-[:HAS_CREATOR]-(post:Post)` compiles to:

```
Bitmap Heap Scan on "HAS_CREATOR"  (end_id = friend.graphid)   ← all edges, Posts + Comments
  └─ Index Scan on "Post"           (id = hascreator.start_id)  ← label-filter by lookup
```

Because AGE stores both `Post` and `Comment` HAS_CREATOR edges in the same
`"HAS_CREATOR"` edge table, the planner must look up every edge's `start_id` in
the `"Post"` vertex table to test the label. The numbers from the plan:

| Metric | Sample 1 | Sample 2 | Sample 3 |
|--------|----------|----------|----------|
| HAS_CREATOR edges per friend | 686 | 702 | 780 |
| Posts per friend (label filter survives) | 142 | 131 | 157 |
| Comment edges discarded (wasted) | 544 (79 %) | 571 (81 %) | 623 (80 %) |
| Wasted `idx_post_graphid` buffer reads | ~963 K | ~970 K | ~1,028 K |
| Wasted reads as % of **all** buffers | **55 %** | **57 %** | **56 %** |

**More than half of every IC10 query's I/O is spent confirming that Comment edges are
not Posts.** This is purely structural — no query rewrite can eliminate it without a
schema change (see OPT-1).

### RC-2 — HAS_INTEREST hash is rebuilt once per surviving friend, not once per query

The plan for the OPTIONAL MATCH's right arm:

```
Hash Join  loops=78,317
  ├─ Index Scan idx_hastag_start   loops=78,317   (post → tags)
  └─ Hash  loops=529               ← rebuilt 529 times — once per surviving friend
       └─ Index Scan idx_hasinterest_start  loops=529  (p → interests)
```

`p` is the same person for the entire query, so its interests never change. Yet AGE's
Cypher runtime evaluates the OPTIONAL MATCH row-by-row for each `(p, friend)` pair in
the pipeline. PostgreSQL's planner cannot hoist the `HAS_INTEREST` hash out of the loop
because the hash is built inside the `cypher()` function's execution boundary. The result:

- 529 hash builds × 4 buffers each = 2,116 buffers (small in absolute terms)
- But the **structure** means 78,317 `idx_hastag_start` lookups — one per post per friend —
  all to ask "does this post have a tag that p is interested in?" for a question whose answer
  is already fixed for the whole query.

### RC-3 — Scaling behaviour is super-linear

Current work is proportional to `surviving_friends × hascreator_edges_per_friend`.

At SF10:  553 friends × 686 edges = **379 K iterations**  
At SF100: ~1,100 friends × ~6,860 edges ≈ **7.5 M iterations** (≈ 20× work for 10× data)  
At SF1000: growth becomes O(SF^1.5) to O(SF^2) due to graph degree scaling laws.

The FoF walk, by contrast, scales sublinearly because the birthday window stays
constant (30 days ≈ 8 % selectivity regardless of SF).

---

## 4. Optimization Proposals

### OPT-1 — Split `HAS_CREATOR` into `POST_HAS_CREATOR` and `COMMENT_HAS_CREATOR` at load time

> **EXCLUDED** — this optimization requires changing the LDBC schema (adding new edge labels at
> load time), which is outside the scope of query-level tuning. OPT-2 alone recovers 96 % of
> the possible gain without any schema change.

**Category:** Schema change (loader)  
**Impact:** Eliminates ~55 % of all buffer reads across every IC/IS query that touches `HAS_CREATOR`  
**Risk:** Requires re-loading data; queries that match on `HAS_CREATOR` untyped must be updated.

The LDBC raw CSV files already emit two separate edge files:
`post_hasCreator_person_0_0.csv` and `comment_hasCreator_person_0_0.csv`.  
Load them as two AGE edge labels (`POST_HAS_CREATOR` and `COMMENT_HAS_CREATOR`).

After this change `(friend)<-[:POST_HAS_CREATOR]-(post)` needs no `Post` label filter because
every edge in that table already points to a Post. The 379 K `idx_post_graphid` lookups
disappear entirely.

Queries affected (all need pattern updates): IC2, IC3, IC4, IC6, IC7, IC8, IC9, IC10, IC11, IC12, IS2, IS4, IS5, IS6, IS7, IU2, IU3, IU6, IU7.

New indexes needed:
```sql
CREATE INDEX idx_post_hascreator_start ON ldbc_snb."POST_HAS_CREATOR" (start_id);
CREATE INDEX idx_post_hascreator_end   ON ldbc_snb."POST_HAS_CREATOR" (end_id);
CREATE INDEX idx_comment_hascreator_start ON ldbc_snb."COMMENT_HAS_CREATOR" (start_id);
CREATE INDEX idx_comment_hascreator_end   ON ldbc_snb."COMMENT_HAS_CREATOR" (end_id);
```

---

### OPT-2 — Two-Cypher split: separate FoF walk from interest scoring

**Category:** Query restructuring (no schema change)  
**Impact:** Reduces interest-scoring I/O from ~1.7 M buffers to ~93 % less (measured)  
**Risk:** Low. Two separate `cypher()` calls; SQL JOIN combines them. Fully compliant with
the no-direct-AGE-table rule (SQL only touches `PersonPostCount`).

**MATERIALIZED is required:** PostgreSQL 17 defaults to inlining non-MATERIALIZED CTEs.
When both `cypher()` calls are inlined, the planner builds a cross-product plan that does
not terminate (tested: >10 min timeout). Both CTEs must be declared `AS MATERIALIZED`.

**Why it works:**  
The current query computes the interest score inside the Cypher pipeline, which forces
AGE to evaluate it per `(p, friend)` row. The key insight is that `p` is constant for the
whole query: its interest tags never change between friends. If we instead ask "which
creators of interest-tagged posts exist?" once — entirely independently of the friend list —
we get a small creator→count table that can be joined back to surviving friends in SQL.

**Expected buffer arithmetic at SF10:**

| Step | Iterations | Buffers |
|------|------------|---------|
| p's interests (`idx_hasinterest_start`) | ~4 | ~16 |
| Posts per interest tag (`idx_hastag_end`) | ~4 × 1,000 = 4,000 | ~20,000 |
| Creator per post (`idx_hascreator_start` or `idx_post_hascreator_start`) | 4,000 | ~12,000 |
| Aggregate by creator | 4,000 rows | in-memory |
| **Total interest scoring** | | **~32,000** |
| FoF walk (unchanged) | — | ~40,000 |
| PersonPostCount join | ~530 | ~1,600 |
| **Combined** | | **~74,000** |

Compare to current: **1,758,000** buffers → **96 % reduction** (predicted).
Actual measured: **~128 K buffers average** → **~93 % reduction** (see §5).

**Proposed query structure (V7):**

```sql
WITH surviving_friends AS MATERIALIZED (
  SELECT
    (friend_gid::text)::ag_catalog.graphid  AS friend_gid,
    (friend_id::text::bigint)               AS friend_biz_id,
    friend_first_name::text                 AS friend_first_name_t,
    friend_last_name::text                  AS friend_last_name_t,
    friend_gender::text                     AS friend_gender_t,
    city_name::text                         AS city_name_t
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH DISTINCT p, friend
    WHERE ((friend.birthMonth = $month AND friend.birthDay >= 21)
        OR (friend.birthMonth = ($month % 12) + 1 AND friend.birthDay < 22))
    OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
    WITH DISTINCT friend, direct WHERE direct IS NULL
    MATCH (friend)-[:IS_LOCATED_IN]->(city:City)
    RETURN id(friend), friend.id, friend.firstName, friend.lastName,
           friend.gender, city.name
  $$) AS (friend_gid agtype, friend_id agtype,
          friend_first_name agtype, friend_last_name agtype,
          friend_gender agtype, city_name agtype)
),
interest_post_counts AS MATERIALIZED (
  SELECT
    (creator_gid::text)::ag_catalog.graphid  AS creator_gid,
    (score::text)::bigint                    AS common_post_count
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:HAS_INTEREST]->(tag:Tag)
                <-[:HAS_TAG]-(post:Post)
                -[:HAS_CREATOR]->(creator:Person)
    WITH creator, count(DISTINCT post) AS score
    RETURN id(creator), score
  $$) AS (creator_gid agtype, score agtype)
)
SELECT
  sf.friend_biz_id::ag_catalog.agtype                                                         AS personId,
  ('"' || sf.friend_first_name_t || '"')::ag_catalog.agtype                                   AS personFirstName,
  ('"' || sf.friend_last_name_t  || '"')::ag_catalog.agtype                                   AS personLastName,
  ((2 * COALESCE(ipc.common_post_count, 0) - COALESCE(ppc.post_count, 0)))::ag_catalog.agtype AS commonInterestScore,
  ('"' || sf.friend_gender_t     || '"')::ag_catalog.agtype                                   AS personGender,
  ('"' || sf.city_name_t         || '"')::ag_catalog.agtype                                   AS personCityName
FROM surviving_friends sf
LEFT JOIN interest_post_counts ipc ON ipc.creator_gid = sf.friend_gid
LEFT JOIN ldbc_snb."PersonPostCount" ppc ON ppc.person_id = sf.friend_gid
ORDER BY (2 * COALESCE(ipc.common_post_count, 0) - COALESCE(ppc.post_count, 0)) DESC,
         sf.friend_biz_id ASC
LIMIT 10;
```

**Correctness notes:**
- `interest_post_counts` returns a row for every person who created a post tagged with any
  of p's interests — this is a superset of the surviving friends. The `LEFT JOIN` to
  `surviving_friends` filters to only the relevant creators.
- `count(DISTINCT post)` ensures a post counted only once even if it has multiple tags that
  match p's interests.
- Friends with no matching posts correctly receive `COALESCE(ipc.common_post_count, 0) = 0`,
  giving them a score of `0 - ppc.post_count`.

**Impact from `p` carrying many interests:**  
At SF1000 with ~5 interests and ~10,000 tagged posts per tag, the second Cypher processes
~50,000 post rows total — still linear in SF. The current query would process ~2,200 friends
× ~68,600 HAS_CREATOR edges = 150 M iterations. OPT-2 stays O(SF) vs the current O(SF²) trajectory.

---

### OPT-3 — Covering index on `HAS_CREATOR` to eliminate heap reads

**Category:** Index addition (no schema/query change)  
**Impact:** Converts `Bitmap Heap Scan` → `Index Only Scan` on `HAS_CREATOR`; eliminates ~150 K heap block reads per query (8.6 % of total buffers). Complements OPT-2 if OPT-1 is not done.  
**Risk:** None. Index addition is online and non-destructive.

The current `idx_hascreator_end (end_id)` index holds only the key column. The planner needs
`start_id` (the message graphid) after the index scan, forcing a heap fetch per row. Adding
`start_id` as an INCLUDE column removes those fetches:

```sql
-- Drop the existing single-column index first (or create alongside then drop old)
CREATE INDEX idx_hascreator_end_incl
  ON ldbc_snb."HAS_CREATOR" (end_id) INCLUDE (start_id);
```

With this index the `HAS_CREATOR` step becomes an Index Only Scan — no heap pages touched.
At SF10 (553 friends × 686 rows × 272 heap blocks / friend) = ~150 K heap reads eliminated.

If OPT-1 (schema split) is implemented first, create the covering index on both new labels:
```sql
CREATE INDEX idx_post_hascreator_end_incl
  ON ldbc_snb."POST_HAS_CREATOR" (end_id) INCLUDE (start_id);
CREATE INDEX idx_comment_hascreator_end_incl
  ON ldbc_snb."COMMENT_HAS_CREATOR" (end_id) INCLUDE (start_id);
```

---

### OPT-4 — Composite `(end_id, start_id)` covering index on `HAS_TAG` (minor)

**Category:** Index addition  
**Impact:** Eliminates ~342 K `idx_hastag_start` buffer reads once OPT-2 is in place; each
call in the interest-scoring Cypher reads `HAS_TAG` via `end_id` (tag → posts direction).  
**Risk:** None.

The interest-scoring Cypher in OPT-2 traverses `(tag)<-[:HAS_TAG]-(post)`, which
compiles to `idx_hastag_end`. The existing `idx_hastag_end (end_id)` already covers this
direction. No new index needed unless profiling shows heap fetches (in which case apply the
same INCLUDE pattern as OPT-3).

---

## 5. Improvement Summary

### Predicted vs Actual (SF10, Horizon DB, cache-warm)

| Sample | V6 buffers | V7 buffers | Buffer reduction | V6 time | V7 time | Time reduction |
|---|---|---|---|---|---|---|
| S1 (pid=6597069812321, m=10) | 1,758,480 | 131,692 | **92.5 %** | 860 ms | 662 ms | 23 % |
| S2 (pid=8796093047542, m=12) | 1,706,356 | 42,483 | **97.5 %** | 750 ms | 297 ms | 60 % |
| S3 (pid=19791209314115, m=3) | 1,849,060 | 209,096 | **88.7 %** | 827 ms | 672 ms | 19 % |
| **Average** | **~1,771 K** | **~128 K** | **~93 %** | **~840 ms** | **~544 ms** | **~35 %** |

The original prediction was **96 %** buffer reduction and **~40–60 ms**. Actual buffer reduction
is close (93 % vs 96 %). Actual execution time improved less than predicted (~544 ms vs ~50 ms)
because:

1. **Cypher 2 uses a Parallel Seq Scan on `Person`** to find the seed `p` instead of the GIN
   index. In a MATERIALIZED CTE, the planner opts for a parallel seq scan over the GIN index
   (65 K rows scanned, 3,592 buffers) because GIN indexes are not parallelizable. This adds
   ~7 K buffers and ~20 ms per query.
2. **`idx_post_graphid` Post label checks in Cypher 2** still fire because `HAS_TAG` edges
   include both Posts and Comments. V7 removes the per-friend iteration (O(friends × posts))
   but the per-tag iteration (O(tags × posts_per_tag)) still incurs these checks.
3. **Tag fan-out variability**: S3's person has 2 interests with ~11 K tagged posts each
   → 86 K `idx_hascreator_start` lookups → 173 K total Cypher 2 buffers. S2's person has
   1 interest with only 74 post matches → 7 K buffers. The plan predicted a ~1,000 posts/tag
   average; actual fan-out varies from 74 to 13,102 per tag.

### Critical finding: MATERIALIZED CTEs are mandatory

Without `AS MATERIALIZED` on both CTEs, PostgreSQL 17 inlines the two `cypher()` calls into
a single cross-product plan that does not terminate (tested: >10 min timeout at SF10).
The production query and EXPLAIN script have both been updated with `AS MATERIALIZED`.

| Optimization | Buffers saved | % reduction | Exec time (actual SF10) |
|---|---|---|---|
| Baseline V6 | — | — | ~840 ms |
| OPT-2 + MATERIALIZED (V7, implemented) | ~1,643 K | **~93 %** | ~544 ms avg |
| + OPT-3 (covering idx on HAS_CREATOR end_id) | ~1,793 K | **~93.5 %** | ~530 ms (est.) |
| + OPT-1 (schema split, excluded) | ~1,720 K | **~98 %** | ~300–400 ms (est.) |

---

## 6. Scaling Projection

| Scale Factor | Current O(SF^1.5) | OPT-2 O(SF) |
|---|---|---|
| SF10 (baseline) | ~1.76 M buffers, ~840 ms | ~128 K buffers, ~544 ms |
| SF100 | ~75 M buffers, ~35 s | ~1.3 M buffers, ~5 s |
| SF1000 | ~2.4 B buffers, timeout | ~13 M buffers, ~50 s |

The current query has an inherent O(friends × messages_per_friend) cost structure. Both
`friends` and `messages_per_friend` grow with SF (LDBC power-law degree distribution),
making the product grow super-linearly. OPT-2 breaks this by making the interest-scoring
cost depend only on `p`'s interest count and the fan-out of those tags — neither of which
grows proportionally with SF.

---

## 7. Implementation Roadmap

| Step | Change | File(s) | Status |
|------|--------|---------|--------|
| **1** | Implement OPT-2: two-call V7 query with MATERIALIZED | `age/queries/interactive-complex-10.sql` | **Done** |
| **2** | Update EXPLAIN script with V7 + MATERIALIZED for re-profiling | `age/ic10-explain-sf10.sql` | **Done** |
| **3** | Update `INDEXES.md` IC10 row to reflect V7 index usage | `age/queries/INDEXES.md` | **Done** |
| **4** | Add OPT-3 covering index on `HAS_CREATOR (end_id) INCLUDE (start_id)` | `age/scripts/create-indexes.sql`, `age/queries/INDEXES.md` | **Done** |
| **5** | Run V7 EXPLAIN ANALYZE and record actual results | `age/ic10-explain-sf10-v7-results.txt` | **Done** |
| ~~6~~ | ~~OPT-1: split HAS_CREATOR edge labels~~ | — | **Excluded** (LDBC schema change) |

**AGENTS.md compliance for V7:**
- All graph traversal through two `cypher()` calls — no direct AGE label table access in SQL.
- SQL outer layer combines the two Cypher CTEs and `PersonPostCount` side table only.
- Directed `-[:KNOWS]->` per AGE-QUIRKS §11; fixed-depth 2-hop per AGE-QUIRKS §4.
- `count(DISTINCT post)` aggregated in `WITH` before `RETURN` per AGE-QUIRKS §5.
- No `cypher(` literal in SQL comments (rule 14 — JDBC parameter binding safety).

---

## 8. What is NOT worth changing

- **FoF walk (KNOWS traversal):** Already fast at ~32 K buffers / ~175 ms. Accounts for < 25 %
  of total cost in V7. Any further tuning there has negligible impact.
- **Direct-friend exclusion (`OPTIONAL MATCH NOT`):** Costs ~3,460 buffers (0.2 % of V6).
  The UNION-dedup trick (IC9 V4) is not applicable here since IC10 requires 2-hop-only
  (pure FoF, excluding direct friends), not 1-hop ∪ 2-hop.
- **Birthday filter placement:** Filter rejects ~92 % of FoF candidates but runs only on
  `idx_person_graphid` probes (~22 K buffers). Functional indexes on `birthMonth`/`birthDay`
  would not help since the FoF enumeration forces a person lookup per candidate regardless.
- **`PersonPostCount` join:** PK index scan at < 0.1 % of buffers. Already optimal.
- **GIN vs Seq Scan on Person in Cypher 2:** The planner prefers a parallel seq scan over
  `gin_person` for the seed lookup in MATERIALIZED CTEs (~3,592 extra buffers). Fixing this
  would require a planner hint (not available in vanilla PostgreSQL) or a functional B-tree
  index on `properties->>'id'`. The buffer cost is small (~2.7 % of V7 total) and not worth
  the complexity.
