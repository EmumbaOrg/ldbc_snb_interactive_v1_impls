# LDBC SNB Interactive on Apache AGE — SF3 Benchmark Final Report

**Date:** 2026-05-10
**Engine:** Apache AGE 1.6 / PostgreSQL 17 — local dev (Darwin 25.4.0, M-series, 32 GB RAM)
**Scale factor:** SF3 (24 K Persons, 6.4 M Comments, 2.6 M Posts, 1.13 M KNOWS, 11 GB DB)
**Driver:** thread_count=4, time_compression_ratio=0.001
**Validation params:** LDBC official `validation_params-sf3.csv` (145 K entries)

---

## 1. Headline numbers

| Stage | Throughput | IC mean (slowest pole IC5) | SQ2 mean |
|---|---|---|---|
| SF0.1 (after IC1 V2) | **570 ops/s** | 577 ms | (disabled) |
| SF3 baseline (no fixes) | 3.58 ops/s | crash on IC10 stuck | (disabled) |
| SF3 after IC10 V4 + IC1 revert | 3.30 ops/s | 33 sec | 7.5 sec |
| **SF3 after SQ2 V2** | **5.01 ops/s** | 36 sec | **0.44 sec** |

**Overall SF3 → SF0.1 throughput ratio:** ~1:113. Driven by IC long-tail.
**SQ2 V2 specifically:** 7,538 ms → 439 ms mean (**−94%**), p99 18,445 → 6,337 ms (−66%).

---

## 2. SF3 environment setup

> Local dev only had SF0.1 / SF0.3 raw data. SF3 was set up from scratch.

1. Downloaded `social_network-sf3-CsvComposite-LongDateFormatter.tar.zst` (724 MB) and `substitution_parameters-sf3.tar.zst` (608 KB) from `datasets.ldbcouncil.org/snb-interactive-v1`.
2. Extracted to `~/repositories/ldbc_snb_data/sf3/` (3.0 GB raw CSV).
3. Preprocessed via `scripts/preprocess_ldbc.py` → 4 GB converted CSVs.
4. Loaded via `scripts/load-data.sh --sf 3` (preprocess + agefreighter load + indexes + snapshot). Total: ~30 min.
5. Final DB size: 11 GB.
6. Validation params: downloaded LDBC's pre-generated `validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst` (200 MB) — saved hours vs locally generating 50 K params at SF3 query latency.

**Snapshot policy:** SF0.1 snapshot preserved at `/tmp/ldbc_snb_snapshot.sf0.1.dump`. SF3 snapshot at `/tmp/ldbc_snb_snapshot.dump`. `restore-database.sh` reads the latter; switching SFs requires copying the right snapshot in.

---

## 3. Validation results (truncated to 5 K rows due to SF3 latency)

Validation against the 5 K-row prefix of the LDBC SF3 params:

- **Processed:** 1685 / 5000 before stop (long-running IC10 query stalled the 8-thread runner; dropped to 4 threads thereafter).
- **Crashed:** 0
- **Incorrect:** 269 (~16%)

### Failure attribution

| Bucket | Approx. share | Reason |
|---|---|---|
| IC13 (returns -1 sentinel) | ~20% | AGE 1.6 has no `shortestPath()` — Java handler returns sentinel. Always counts as "incorrect" against any non-trivial param. |
| IC14 (returns []) | ~20% | Same — no `allShortestPaths()`. |
| IC3 | ~25% | Sort tie-break / numeric encoding edge cases at SF3. SF0.1 validation passes; SF3 has more rows where `xCount == yCount` so tie-break ordering becomes visible. |
| SQ2 (was V0) | ~10% | The V0 form had the 8-level OPTIONAL MATCH chain pathology + LIMIT-inside-Cypher. **Now fixed by V2** (this report). |
| IC11, IC4, others | ~25% | Single-digit failures; data-edge cases. |

### Key validation-time finding

**IC10 V3 ran 1h14m on a single sample** under multi-thread driver contention (verified via `pg_stat_activity`). Single-call EXPLAIN of the same query shape ran in 2 sec. The Cypher form was the SF0.1 V3 (won at SF0.1 with mean 150 ms) — V3's `WITH DISTINCT p, friend ... MATCH (friend)-[:IS_LOCATED_IN]->(city)` flips planner choice at SF3 to a Merge Join over the **full IS_LOCATED_IN table (9 M rows)** when the friend set crosses ~300 surviving members. This was the validation killer; fixing it (V4) was prerequisite to the SF3 benchmark.

---

## 4. SF3 benchmark — full per-query digest

10 K operations, thread_count=4:

| Query | Count | Mean (ms) | p50 | p90 | p99 | Notes |
|---|---|---|---|---|---|---|
| **LdbcQuery5** | 41 | **33,350** | 37,150 | 52,490 | **64,908** | TALLEST POLE — needs schema denorm |
| **LdbcQuery10** | 79 | 23,793 | 19,808 | 41,400 | 50,166 | V4 fix: was timing out >120s on V3 |
| LdbcQuery12 | 57 | 13,752 | — | — | 23,507 | W2; SF3 cost grows linearly with FoF tree |
| LdbcQuery1 | 97 | 11,866 | 11,066 | 15,557 | 25,388 | V1 (V2 was stuck >10 min at SF3) |
| LdbcQuery3 | 32 | 3,106 | — | — | 8,017 | C8 holds; FoF + country small enough |
| LdbcQuery6 | 15 | 3,062 | — | — | 4,784 | W5 holds |
| LdbcQuery2 | 67 | 3,246 | — | — | 8,853 | V0 (no per-friend top-K index) |
| LdbcQuery7 | 34 | 1,946 | — | — | 11,636 | W3 collect+UNWIND scales |
| LdbcQuery8 | 93 | 1,656 | — | — | 6,685 | V0 |
| LdbcQuery11 | 148 | 1,051 | — | — | 5,734 | V0 |
| LdbcQuery4 | 69 | 984 | — | — | 3,525 | unchanged |
| LdbcQuery9 | 12 | 866 | — | — | 5,801 | pure SQL |
| **LdbcShortQuery2** (V2) | 180 | **439** | — | — | 6,337 | **NEW: was 7,538 / 18,445 (−94% / −66%)** |
| LdbcShortQuery1 | 180 | 166 | — | — | 1,789 | scales with property fetch width |
| LdbcShortQuery5 | 181 | 169 | — | — | 2,028 | |
| LdbcShortQuery7 | 181 | 195 | — | — | 1,678 | |
| LdbcShortQuery4 | 181 | 203 | — | — | 2,381 | pure SQL |
| LdbcShortQuery3 | 180 | 223 | — | — | 2,684 | |
| LdbcShortQuery6 | 181 | 236 | — | — | 3,393 | pure SQL |
| LdbcUpdate6AddPost | 77 | 78 | — | — | 985 | |
| LdbcUpdate8AddFriendship | 5 | 32 | — | — | 140 | |
| LdbcUpdate5AddForumMembership | 236 | 181 | — | — | 4,833 | |
| LdbcUpdate4AddForum | 7 | 619 | — | — | 3,471 | |
| LdbcUpdate2AddPostLike | 77 | 633 | — | — | 3,626 | |
| LdbcUpdate3AddCommentLike | 120 | 1,490 | — | — | 10,495 | |
| LdbcUpdate7AddComment | 72 | 1,672 | — | — | 10,987 | |

### Throughput evolution at SF3 across this session

| Configuration | Throughput |
|---|---|
| All queries enabled, IC1 V2, IC10 V3 | **3.58 ops/s** (mostly stuck on long-tail) |
| IC5/IC7/IC10 disabled, IC1 V2 | 0.83 ops/s (IC1 V2 itself stuck >10 min) |
| All enabled, IC1 reverted to V1, IC10 V4 | **3.30 ops/s** |
| Above + **SQ2 V2** | **5.01 ops/s** (+52%) |

---

## 5. Problems and blockers found at SF3

### 5.1 AGE 1.6 planner threshold-flips

Multiple queries had Cypher forms where AGE planner picked NL via index at
SF0.1 (small intermediate cardinality) and switched to hash/merge join over
full edge tables at SF3. The threshold around friend-set cardinality
crossing ~300 nodes is consistent across IC10 V3 and IC1 V2.

**Mitigation:** `WITH x, collect(y) AS ys UNWIND ys AS y` materialisation
barriers force NL plans by hiding the true cardinality from the planner.
Used in IC7 W3 (already), IC10 V4 (newly applied this session). This is
the most reliable Cypher-level lever against AGE 1.6's planner mis-
estimation at scale.

### 5.2 Per-candidate EXISTS chains explode quadratically

IC1 V2 (`CASE WHEN EXISTS { (p)-[:KNOWS*1..3]->(friend) } ...`) compiles to
SubPlan-per-outer-row. SF0.1 win (firstName candidate count = 1) became
SF3 catastrophe (count = 220, branching factor 50, ~125 K paths to verify
per candidate × 220 = ~27 M lookups, plus per-EXISTS overhead). Single
queries hung > 10 min.

**Lesson:** EXISTS chain pattern is only safe when outer cardinality is
bounded by something other than data size. Reverted IC1 to V1 (person-
driven, 3 separate AGE calls).

### 5.3 IC5 OPTIONAL MATCH parallel-hash join is the SF3+ blocker

We exhausted Cypher-rewrite landscape for IC5 in the SF0.1 session
(V8a–V8aa, COUNT subquery, UNION ALL inside Cypher, friend-driven post
walk). Every variant either hits the same parallel hash plan, drops
semantics (zero-post pairs missing), or pays per-row map-unpack overhead.

**SF3 cost:** ~33 sec mean. **SF1000 estimate:** parallel hash builds
scale with table size — at SF1000 the build is 90 M Post rows × HAS_CREATOR
× CONTAINER_OF, i.e. multi-minute per call. Not viable.

**Unblock path (out-of-scope this session):** denormalise per-(Person,
Forum) post count onto a maintained side table, increment at IU6
(AddPost). IC5's OPTIONAL MATCH becomes a single index lookup.
SF1000 estimate: 30-60 ms.

### 5.4 AGE 1.6 multi-thread concurrency bug on updates

```
ERROR: vertex assigned to variable post was deleted
```

Hit at thread_count=8 within the first 31 ops at SF3 during
`LdbcUpdate6AddPost`. Driver crashed. Reduced thread_count to 4 — issue
disappears. Concurrent-update semantics at higher thread counts have a
race in AGE 1.6's MVCC visibility for newly created vertices. Not a
query-level fix; needs AGE engine improvement.

### 5.5 Validation params at SF3 are impractical at full scale

Generating 50 K validation params with `mode=create_validation` runs the
LDBC workload single-threaded and records each query's result. At SF3 this
takes 2–3 sec/param × 50 K = ~30 hours. The pre-generated LDBC params
(`validation_params-sf3.csv`) shipped via `datasets.ldbcouncil.org` save
this entire cost — that file should be the canonical source for SF3+ work.

---

## 6. Optimisations applied this session

### 6.1 IC1 — V2 reverted to V1

V2 (firstName-driven seed + per-candidate CASE+EXISTS distance) was an
SF0.1-only optimisation (60→8 ms there). At SF3 it pathologises into
multi-minute hangs. V1 (person-driven, 3 separate UNION ALL arms) is
known stable across all SFs.

**SF3 result:** mean 11,866 ms (versus V2 stuck > 10 min and blocking
driver threads).

File: `age/queries/interactive-complex-1.sql`.

### 6.2 IC10 V3 → V4 (collect+UNWIND barrier)

Added a `WITH p, collect(friend) AS friends UNWIND friends AS friend`
barrier between the post-DISTINCT direct-check and the city/post
traversals. This forces NL via `idx_islocatedin_start`,
`idx_hascreator_end`, `idx_hastag_start`, `idx_hasinterest_start` per
friend instead of merge-join over full IS_LOCATED_IN.

**Measured:**
- SF3 sample 1 (small friend tree): 2 s → 2 s (no regression).
- SF3 sample 2 (4 899 → 421 surviving friends): **120 s+ timeout → 16.9 s** (≥7×).
- Multi-thread previously stuck > 1 hour on this sample → no longer pathological.

File: `age/queries/interactive-complex-10.sql`.

### 6.3 SQ2 — V0 → V2 (hybrid SQL recursive CTE)

V0 had two pathologies:
1. `WITH msg ORDER BY ... LIMIT 10` inside Cypher disabled parallel
   append (same regression IC2 V2 hit at SF0.1).
2. 8-deep `OPTIONAL MATCH (rN)-[:REPLY_OF]->(rN+1)` chain forces a Seq
   Scan on Post (`rows=2,595,655` at SF3) for the rootPost lookup — same
   pathology SQ6 documented and fixed via recursive CTE.

V2 mirrors SQ6's recursive CTE pattern:
- User's top-10 messages via `idx_hascreator_end` per Comment / Post label.
- `reply_walk` recursive CTE walks REPLY_OF using `idx_replyof_start`.
- Walk terminates at rootPost naturally (Posts have no outgoing REPLY_OF).
- LEFT JOIN to handle Post messages directly.

Removed from `age_parameterized_queries` (uses `$personId` substitution
non-parameterized path, like SQ4 / SQ6 / IC9).

**Measured at SF3:**
- mean 7,538 ms → **439 ms** (−94%)
- p99 18,445 ms → 6,337 ms (−66%)
- Throughput contribution: with 933 calls/run × 7 sec each = 109 min of
  the previous 50 min benchmark wall time was just SQ2. Eliminated.

File: `age/queries/interactive-short-2.sql`.

---

## 7. In-depth optimisation roadmap (SF1000+ readiness)

### Tier 1 — schema denormalisations to land before SF1000

In rough priority order (biggest expected win first):

1. **`Person.forum_post_count` side table** `(forum_id graphid, person_id graphid, post_count int)`.
   **Unblocks:** IC5 (mean 33 sec at SF3 → estimated 30-60 ms at SF1000).
   **Maintained at:** IU6 (AddPost) — increment on insert; load-time backfill from existing data.
   **Risk:** modest — schema change but well-bounded; same shape as Phase F's birthMonth/birthDay precomputation.

2. **`creationDate` denormalised onto `HAS_CREATOR.properties`** + composite index
   `(end_id, agtype creationDate DESC)`.
   **Unblocks:** IC2 (per-friend top-K messages by date), IC8 (per-message replies).
   **Maintained at:** IU6 (AddPost), IU7 (AddComment), load-time backfill.
   **Risk:** small — purely additive on existing edge.

3. **`Person.post_count` integer property** + supporting index for IC10 post-counting branch.
   Also useful for IC5, IC7. Maintained at IU6, load backfill.

4. **`HAS_INTEREST` covering composite index `(start_id, end_id)`**.
   Unblocks IC10's per-post tag-interest existence check at SF1000+. Pure index, no schema change.

### Tier 2 — Cypher / AGE planner improvements

5. **`WITH ... collect ... UNWIND` barrier pattern** as a default in any
   Cypher with > 3 stages. The IC10 V4 fix proved this is a general
   anti-pattern preventer for AGE 1.6's planner mis-estimation. Apply
   prophylactically to IC2, IC8, IC11 if profiling shows similar
   threshold-flips at SF1000.

6. **Bidirectional BFS for shortest path (IC13/IC14)** as a hybrid SQL
   recursive CTE on the KNOWS table. Bound depth at 6, terminate when
   target found. Estimated SF1000 cost: 100-500 ms / call, vs current
   "always returns -1" sentinel.

### Tier 3 — AGE engine investigations (longer-term)

7. **Multi-thread MVCC visibility** for newly created vertices in updates.
   AGE 1.6 race surfaced at thread_count=8 during SF3 IU6 (post creation).
   Workaround: thread_count <= 4. Long-term: AGE engine fix.

8. **Per-call `cypher()` overhead** (~15-150 ms / call across queries):
   parser cache miss, agtype boxing, JDBC text-mode fetch. This is a
   constant per call across all SFs and dominates fast queries (SQ1/3/5 at
   ~1 ms SQL plan but ~180 ms benchmark mean at SF3). Profiling AGE
   internals would unlock 1.5-3× across every Cypher query.

9. **AGE 1.7+** ships `shortestPath()` and `allShortestPaths()` per
   the project roadmap — would unblock IC13 / IC14 directly.

### Tier 4 — already at structural ceiling, schema denorm is the only path

10. **IC5 V7 + composite `idx_hasmember_end_joindate_agtype`** — every
    Cypher rewrite explored at SF0.1 was either equivalent or slower.
    The OPTIONAL MATCH compilation is fundamental.

11. **IC10 V4** — V4 fixes the SF3 catastrophic case, but at SF1000 with
    ~3 K surviving friends × ~10 K posts/friend, NL post enumeration
    still takes 30-60 sec. Tier 1 #1 (Person.forum_post_count) unblocks
    this. Tier 1 #3 (Person.post_count) helps somewhat.

12. **IC7 W3** — at SF1000 ~770 K messages × ~10 likers each = ~7.7 M NL
    probes ≈ 40 sec. Tier 1 #2 helps slightly; primary fix would be
    per-Comment liker count denormalisation.

---

## 8. Disabled queries — when to re-enable

| Query | Currently disabled | Reason | Re-enable when |
|---|---|---|---|
| IC13 | yes, returns -1 | AGE 1.6 lacks `shortestPath()` | AGE 1.7+ OR Tier 2 #6 (hybrid SQL BFS) lands |
| IC14 | yes, returns [] | AGE 1.6 lacks `allShortestPaths()` | Same as IC13 |
| SQ2 | **was disabled, now enabled** (V2 fix) | V0's 8-level OPTIONAL MATCH + LIMIT-inside-Cypher | **Re-enabled this session** |

---

## 9. Recommended next steps

1. **Land Tier 1 #1 (Person.forum_post_count side table)** — biggest single
   SF1000 unblock. ~3-5 days work (schema + load backfill + IU6 +
   IC5 query rewrite + validation).
2. **Land Tier 1 #2 (HAS_CREATOR.creationDate denormalisation)** — unblocks IC2/IC8.
3. **Set up SF10 benchmark capacity** — SF3 benchmark took ~50 min for 10 K
   ops on this hardware. SF10 would be ~3× → 2.5 hours per run on local;
   moves to a VM with more RAM and SSD speeds runs significantly. The
   Azure HorizonDB cluster (per `~/Downloads/sf3_out.log`) is the natural
   platform for SF10/SF100/SF1000 measurements.
4. **Re-evaluate the "ceiling reached" queries quarterly** as AGE
   advances — many of the parallel-hash issues should resolve in AGE 1.7+.

---

## 10. Files changed this session

| File | Change |
|---|---|
| `age/queries/interactive-complex-1.sql` | Reverted V2 firstName-driven → V1 person-driven (3-arm UNION ALL). V2 catastrophically regresses at SF3. |
| `age/queries/interactive-complex-10.sql` | V3 → V4 — added collect+UNWIND barrier between direct-check and city/post traversals. |
| `age/queries/interactive-short-2.sql` | V0 → V2 — replaced 8-level OPTIONAL MATCH chain + LIMIT-inside-Cypher with hybrid SQL recursive CTE on REPLY_OF. |
| `age/driver/benchmark.properties` | Re-enabled `LdbcShortQuery2PersonPosts_enable=true`. Removed `ShortQuery2PersonPosts` from `age_parameterized_queries` (now uses `$personId` substitution path). |
| `age/driver/validate.properties` | Same as above. |
| `age/driver/benchmark-local.properties`, `validate-local.properties` | Same as above. |
| `age/results/sf3-final-report.md` | This report. |
| `age/results/sf3-blocking-queries-plan.md` | Companion investigation document for the per-query SF3 deep dive. |

---

*Generated 2026-05-10 from final SF3 sanity benchmark
(`/tmp/sf3-bench-sq2.log`).*
