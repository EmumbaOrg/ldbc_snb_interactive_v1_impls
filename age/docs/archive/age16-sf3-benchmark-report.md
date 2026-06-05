# AGE 1.6 / SF3 Benchmark Report — 2026-05-12

## Executive Summary

| Metric | This run | Baseline (AGE 1.7 / PG18) | Delta |
|---|---|---|---|
| Throughput | **7.918 ops/s** | 5.28 ops/s | **+49.9%** |
| Duration | 2,522 s | 3,785 s | −33.4% |
| Total ops | 19,971 | 19,968 | ≈ same |
| Errors | 0 | — | — |
| MVCC skips | **0** | — | bug not triggered |

**Pass.** The run completed cleanly. Throughput improved 50% over baseline, driven primarily by the IS5 (ShortQuery5MessageCreator) rewrite which eliminated per-call AGE plan compilation overhead. The AGE 1.6 MVCC bug was not triggered at thread_count=4.

---

## Environment

| Parameter | Value |
|---|---|
| AGE version | 1.6.0 (`apache/age:release_PG17_1.6.0`) |
| PostgreSQL version | 17.7 |
| Container | `Pg17Age1.6` |
| Scale factor | SF3 |
| Operations | 20,000 |
| Warmup | 2,000 |
| thread_count | 4 |
| age_connection_pool_size | 4 |
| shared_buffers | 4 GB |
| work_mem | 64 MB |
| max_parallel_workers | 8 |
| max_parallel_workers_per_gather | 4 |
| jit | off |
| /dev/shm | 2 GB |
| Host | macOS / Apple M2 Pro, 16 GB RAM |

---

## Overall Results vs Baseline

| Metric | This run | Baseline | Delta |
|---|---|---|---|
| Throughput (ops/s) | 7.918 | 5.28 | +49.9% |
| Duration (s) | 2,522 | 3,785 | −33.4% |
| Total ops | 19,971 | 19,968 | +0.0% |

---

## Per-Query Results

All latency values are in **milliseconds** as reported by the LDBC driver (`run_time.unit: MILLISECONDS`).
Regressions >20% vs baseline mean are marked **(!)**.
IU1 has n=2 — too few samples for statistical significance.

### Complex Reads (IC)

| Query | n | Mean (ms) | p99 (ms) | Baseline mean (ms) | Baseline p99 (ms) | Delta mean |
|---|---|---|---|---|---|---|
| IC1 | 193 | 1,080 | 7,304 | 800 | 6,600 | +35.0% |
| IC2 | 135 | 320 | 2,445 | 200 | 1,100 | +60.0% (!) |
| IC3 | 64 | 1,304 | 4,578 | 1,000 | 2,900 | +30.4% (!) |
| IC4 | 140 | 880 | 2,732 | 700 | 1,600 | +25.7% (!) |
| IC5 | 82 | 3,220 | 15,569 | 2,100 | 5,900 | +53.3% (!) |
| IC6 | 29 | 1,212 | 3,862 | 1,000 | 1,700 | +21.2% (!) |
| IC7 | 70 | 1,759 | 11,559 | 1,100 | 3,600 | +59.9% (!) |
| IC8 | 185 | 509 | 2,703 | 400 | 1,400 | +27.3% (!) |
| IC9 | 24 | 181 | 853 | 100 | 200 | +81.0% (!) |
| IC10 | 157 | 681 | 5,048 | 400 | 1,600 | +70.3% (!) |
| IC11 | 295 | 462 | 1,765 | 400 | 1,500 | +15.5% |
| IC12 | 114 | 1,050 | 3,172 | 900 | 2,100 | +16.7% |

### Short Reads (IS)

| Query | n | Mean (ms) | p99 (ms) | Baseline mean (ms) | Baseline p99 (ms) | Delta mean |
|---|---|---|---|---|---|---|
| IS1 ShortQuery1PersonProfile | 1,847 | 85 | 1,118 | 100 | 800 | −15.0% |
| IS2 ShortQuery2PersonPosts | 1,847 | 123 | 1,224 | 100 | 800 | +23.0% (!) |
| IS3 ShortQuery3PersonFriends | 1,847 | 81 | 1,011 | 100 | 900 | −19.0% |
| IS4 ShortQuery4MessageContent | 1,830 | **4,206** | 9,886 | 3,700 | 7,900 | +13.7% |
| IS5 ShortQuery5MessageCreator | 1,830 | **89** | 1,134 | 3,700 | 8,100 | **−97.6%** ✓ |
| IS6 ShortQuery6MessageForum | 1,830 | 67 | 1,017 | 100 | 800 | −33.0% |
| IS7 ShortQuery7MessageReplies | 1,830 | 117 | 1,243 | 100 | 700 | +17.0% |

### Updates (IU)

| Query | n | Mean (ms) | p99 (ms) | Baseline mean (ms) | Baseline p99 (ms) | Delta mean |
|---|---|---|---|---|---|---|
| IU1 AddPerson | 2 | 1,925 | 3,681 | 600 | 1,000 | +220.8% (!) ⚠ n=2 |
| IU2 AddPostLike | 780 | 377 | 2,598 | 400 | 3,100 | −5.8% |
| IU3 AddCommentLike | 966 | 740 | 4,025 | 600 | 3,000 | +23.3% (!) |
| IU4 AddForum | 47 | 132 | 1,185 | 100 | 2,100 | +32.0% (!) |
| IU5 AddForumMembership | 2,426 | 160 | 2,112 | 300 | 2,500 | −46.7% |
| IU6 AddPost | 531 | 310 | 3,341 | 300 | 2,800 | +3.3% |
| IU7 AddComment | 771 | 481 | 4,165 | 500 | 3,000 | −3.8% |
| IU8 AddFriendship | 99 | 177 | 1,537 | 300 | 2,300 | −41.0% |

---

## MVCC Bug (AGE 1.6 Multi-Thread Race)

| Item | Result |
|---|---|
| Bug triggered | **No** |
| Total skips | **0** |
| Skip log | `/tmp/age-mvcc-skips.log` absent |
| Skip rate | 0.00% of update ops |

**Per-operation breakdown** (all zero):

| Operation | Skips | Notes |
|---|---|---|
| IU1 AddPerson | 0 | High susceptibility (many CREATEs) |
| IU4 AddForum | 0 | Medium susceptibility |
| IU6 AddPost | 0 | High susceptibility |
| IU7 AddComment | 0 | High susceptibility (most-reported historically) |
| IU2/IU3/IU5/IU8 | 0 | Low susceptibility (single-edge CREATE) |

Total update ops: 5,622 (IU1=2, IU2=780, IU3=966, IU4=47, IU5=2,426, IU6=531, IU7=771, IU8=99).

The MVCC bug documented in `AGE-1.6-MVCC-BUG.md` (upstream issue #1954) was **not triggered** in this run. Consistent with documentation: at thread_count=4 the timing windows are uncommon. The retry+skip workaround in `AgeUpdateOperationHandler.java` remains in place as a defensive no-op.

**Action:** Run a dedicated stress test at thread_count=8 before any production deployment.

---

## Analysis

### IS5 Improvement: −97.6% (3,700 ms → 89 ms)

The dominant driver of the 50% throughput gain. `ShortQuery5MessageCreator` was rewritten to use parameterized Cypher via `age_parameterized_queries`, bypassing per-call AGE plan compilation overhead. IS5 dropped from 3,700 ms to 89 ms per call — a saving of 3,611 ms per operation. With 1,830 IS5 ops distributed across 4 threads, this eliminates roughly **1,652 wall-clock seconds** of IS5 execution time (6,608 thread-seconds total), which accounts for most of the observed 1,263-second duration improvement (3,785 s → 2,522 s). IS5 now matches IS1 (85 ms), IS3 (81 ms), and IS6 (67 ms) — all parameterized queries running at JDBC round-trip speed.

### IS4 Anomaly: Still 4,206 ms

`ShortQuery4MessageContent` is now the sole outlier in the short-read group. At 4,206 ms it is **47× slower** than IS5 (89 ms) despite both queries doing equivalent single-message lookups. IS4 was not included in the parameterized Cypher rewrite. With 1,830 IS4 calls per 20k run:

- Cumulative IS4 thread time: 1,830 × 4,206 ms = **7,697 seconds** across 4 threads
- IS4 alone consumes ~76% of each thread's 2,522-second budget
- Fixing IS4 to IS5 levels would save **~1,884 wall-clock seconds**, reducing benchmark duration from 2,522 s to ~638 s and pushing **throughput from 7.9 ops/s to ~31 ops/s**

This is the single highest-impact remaining optimization target.

### IC Regressions vs Baseline

Nearly every IC query shows a mean regression of 20–80%. Two factors explain this:

1. **Version delta (AGE 1.6 vs 1.7 / PG17 vs PG18):** The baseline ran on PG18 + AGE 1.7. PG17 and PG18 produce different query plans for Cypher-over-SQL hybrid queries, especially join-heavy traversals like IC5 and IC7.
2. **p99 inflation on IC5 and IC7:** IC5 p99 jumped from 5,900 ms to 15,569 ms (+164%) and IC7 p99 from 3,600 ms to 11,559 ms (+221%). Both perform multi-hop graph traversals with hash join stages that likely spill to disk under PG17's planner. `EXPLAIN (ANALYZE, BUFFERS)` should be run to confirm.

Despite IC regressions, overall throughput is 50% better because ICs account for only ~7% of total ops while the IS improvement (~64% of ops) dominates.

### IC10 p99 Regression (+215%)

IC10 p99 jumped from 1,600 ms to 5,048 ms. IC10 uses the precomputed `birthMonth`/`birthDay` denorm columns on `Person`. The index on `(birthMonth, birthDay)` may not be covering under PG17's cost model, causing heap fetches not needed under PG18. Verify with `EXPLAIN (ANALYZE, BUFFERS)`.

### IC9 Percentage Spike (+81%)

IC9 went from 100 ms to 181 ms — a large percentage but an 81 ms absolute delta with only 24 samples. Not actionable at SF3; dismiss unless the same pattern appears at SF10+.

### IU1 Regression (+220%, n=2)

Only 2 AddPerson operations were scheduled, making the 220% delta statistically meaningless. IU1 requires a higher operation count or a separate microbenchmark to characterize reliably.

### IU Improvements

IU5 (−47%), IU8 (−41%), IU2 (−6%), IU7 (−4%) all improved vs baseline. These use single-edge `CREATE` patterns and benefit from the parameterized Cypher implementation.

### Docker /dev/shm Note

This run required a container with `--shm-size=2g`. The default 64 MB Docker `/dev/shm` is exhausted by PostgreSQL's parallel hash join allocations at `max_parallel_workers=8` during SF3 benchmarks, causing a `No space left on device` crash mid-run. The `--shm-size=2g` requirement is now documented in `scripts/runbook.md`.

---

## Next Steps (ordered by expected impact)

### 1. Fix IS4 (ShortQuery4MessageContent) — Critical impact

IS5 was rewritten with parameterized Cypher and dropped from 3,700 ms to 89 ms. IS4 still runs at 4,206 ms doing equivalent work. IS4 currently consumes 76% of all thread time and is the primary bottleneck. Apply the same treatment: parameterized Cypher or a pure SQL `UNION ALL` across `Post` and `Comment` with `LIMIT 1`. A successful fix would reduce benchmark duration from 2,522 s to ~638 s and push throughput to **~31 ops/s**.

### 2. Investigate IC5 and IC7 p99 spikes — Medium impact

IC5 p99 is 15,569 ms (baseline 5,900 ms, +164%) and IC7 p99 is 11,559 ms (baseline 3,600 ms, +221%). Run `EXPLAIN (ANALYZE, BUFFERS)` on both queries against the AGE 1.6 / PG17 container to identify whether the planner switched to a worse plan (seq scan vs index scan, in-memory vs disk hash join). If a plan regression is confirmed, add a join-order hint or rewrite the CTE structure.

### 3. Run MVCC stress test at thread_count=8 — Safety gate

The MVCC bug was not triggered at thread_count=4, but it has been observed at thread_count=8 on SF3. Run a dedicated stress pass (10,000 IU-only ops at thread_count=8) before any production deployment to confirm the retry workaround holds.

### 4. Investigate IC10 p99 regression (+215%) — Medium impact

IC10 p99 jumped from 1,600 ms to 5,048 ms. Run `EXPLAIN (ANALYZE, BUFFERS)` to confirm the `(birthMonth, birthDay)` index on `Person` is being used and is not reverting to a seq scan under PG17.

### 5. Add covering index for IC2 — Low impact

IC2 mean increased from 200 ms to 320 ms (+60%). A covering index on `Post(creator_id, creationDate DESC)` including `imageFile`, `locationIP`, `browserUsed`, `content` may eliminate the heap fetch and restore baseline performance.

### 6. Upgrade to AGE 1.7 — Correctness / multi-thread readiness

AGE 1.7 fixes the MVCC `curcid` synchronisation bug (upstream PR #2343). This is the correct long-term fix over the retry workaround, and PG18 planning improvements would recover the IC regressions seen here. Steps: (a) confirm Cypher syntax compatibility, (b) re-run validation at SF0.1 + SF3, (c) remove the retry workaround, (d) re-run at thread_count=8.

### 7. Integrate `denormalize-schema.sql` into `load-data.sh` — Operational hygiene

`load-data.sh` does not call `denormalize-schema.sql`, so a fresh data load produces a snapshot without the denorm tables (e.g. `PersonPostCount`). Add `denormalize-schema.sql` as a step in `load-data.sh` between index creation and the pg_dump snapshot so future loads are self-contained.
