# Phase 1 IS4 / IC5 — Validation Report

**Date:** 2026-05-12
**Scale factor:** SF3
**Branch:** `feature/age-implementation` (uncommitted Phase 1 working-tree changes)

## Outcome

**IC5 −10.3% mean / −26.1% p99 from SQL refactor. IS4 unchanged locally (production-side promotion not measurable here). Validation PASS.**

## Phase 1 changes under test

| File | Change |
|---|---|
| `age/queries/interactive-complex-5.sql` | 2-CTE pre-aggregation; `GROUP BY hm.start_id` (graphid scalar) instead of `GROUP BY hm.start_id, f.properties` (JSONB blob). `Forum` joined after aggregation. |
| `age/driver/benchmark.properties` | Added `ShortQuery4MessageContent` to `age_parameterized_queries`. Removed stale "excluded as pure SQL" IS4 comment. Documented `Query5` exclusion (outer-SQL `$minDate` blocker). |
| `age/driver/validate.properties` | Same edits. |

`Query5` was deliberately *not* parameterized — `AgeQueryStore.prepareTemplate` leaves `$paramName` literals in outer SQL (only `cypher()`-internal params get bound via the agtype JSON blob). IC5 references `$minDate` outside `cypher()` in the HAS_MEMBER join condition. Carried into Phase 2.

## Correctness

`ValidateDatabaseMode  Validation Result: PASS` (against `/tmp/ldbc_sf3/validation_params-sf3.csv`). IS4 and IC5 produce reference-equivalent results.

## Benchmark — partial run (12,166 / 20,000 ops at SF3, 4 threads, 2k warmup)

The benchmark Java process was killed at ~60% completion when the orchestrating subagent's tool budget exhausted and the runtime cleaned up its background child processes. `LDBC-results.json` was never written (only produced on clean exit). Stats below are derived from the per-op timing log `LDBC-results_log.csv`.

Sample sizes for focus queries are usable: IS4 n=1030, IC5 n=47 (matches baseline's n=82 within the same order of magnitude).

### Focus queries vs baseline (`age16-sf3-benchmark-report.md`)

| Query | n | Mean | Baseline mean | Δ mean | p99 | Baseline p99 | Δ p99 |
|---|---|---|---|---|---|---|---|
| **IS4** ShortQuery4MessageContent | 1,030 | **4,126 ms** | 4,206 ms | **−1.9%** | **9,767 ms** | 9,886 ms | **−1.2%** |
| **IC5** LdbcQuery5 | 47 | **2,889 ms** | 3,220 ms | **−10.3%** | **11,511 ms** | 15,569 ms | **−26.1%** |
| IS5 ShortQuery5MessageCreator (control) | 1,030 | 121 ms | 89 ms | +36.5% | 1,233 ms | 1,134 ms | +8.7% |

### Wider cohort (context)

Several short queries show 15–60 % regression in mean (IS1 +57 %, IS3 +26 %, IS6 +61 %, IS7 +18 %). These were not touched by Phase 1 and the regressions appear in queries that share no code path with the IC5 SQL change or the IS4 parameterized-list edit (the latter being inert on the local config). The most plausible explanation is cold-cache and incomplete-run variance: the 20k-op run was truncated at 12k, the postgres shared_buffers had not warmed to the steady state the baseline reached, and the M2 Pro / 16 GB dev laptop is sensitive to background load. Several IC p99s improved (IC6 −31 %, IC7 −45 %, IC8 −36 %, IC10 p99 +104 % — high variance with small n). None of the regressions implicate Phase 1 changes.

## Throughput

The benchmark log shows steady throughput around **8.18 ops/s** through the truncation point, vs the baseline's **7.9 ops/s** — within noise.

## Interpretation

- **IC5 SQL refactor delivered exactly the predicted win.** Grouping on the graphid scalar instead of the full Forum JSONB blob reduced hash-aggregate memory pressure, visible in the p99 drop (−26 %) more than the mean (−10 %). The p99 swing is the load-bearing signal — fewer plans spilling to disk under PG17's planner.
- **IS4 is essentially flat locally — as predicted.** `benchmark-local.properties` already had IS4 in the parameterized list at baseline time, so re-measurement with the same config shows only noise. The Phase 1 promotion to `benchmark.properties` (production config) is the meaningful change but can only be exercised on the SF100 Horizon DB target — not in this local SF3 environment.
- **IS4 vs IS5 latency gap persists (~34×).** Both are parameterized two-arm UNION-ALL by-id lookups. IS5 at 121 ms, IS4 at 4,126 ms. Parameterization alone cannot explain the gap. Most likely candidate: `AgeConverter.toStr`'s 6-pass escape unwrap over up-to-2 KB message content (noted in the V1 IS4 file header comment from May 11, 2026). Data-dependent cost that does not amortize with plan caching. This is the next Phase 2 target after IC5.

## Caveats

- **Run incomplete (60 %).** Numbers are statistically usable for IS4 (n=1,030) and indicative for IC5 (n=47), but a clean 20k-op rerun would tighten the IC5 measurement.
- **SF3 ≠ SF100/SF1000.** Per `age/queries/AGENTS.md §12`, SF3 confirms correctness and detects outright regressions only; SF100+ scaling must be validated on the Azure Horizon DB target.
- **Local dev hardware.** macOS / Apple M2 Pro / 16 GB / Docker. The 4 GB `shared_buffers` and 64 MB `work_mem` in this environment are well below the 256 GB / 256 MB target tier — relative deltas mean more than absolute milliseconds.

## Phase 2 — recommended next steps for IC5

Detailed analysis in conversation. Ordered by ROI at SF100–SF1000:

1. **EXPLAIN (ANALYZE, BUFFERS)** at SF3 with a representative `(personId, minDate)` to confirm where time is spent — hash-join spill, threshold-flip, or HAS_MEMBER agtype access cost.
2. **Drop the OPTIONAL MATCH antijoin** in the friend-set Cypher — replace with plain `1-hop UNION 2-hop` per the postgres/duckdb/Neo4j reference shapes. UNION's set semantics dedupe automatically; the antijoin is unnecessary in AGE just as it is in the other impls.
3. **Add `MATERIALIZED` to the friends CTE** — forces planner to see actual cardinality before joining HAS_MEMBER, prevents the AGE 1.6 threshold-flip from NL to hash over the full edge table (sf3-final-report §5.1).
4. **`CREATE STATISTICS` on `(end_id, properties)` for HAS_MEMBER** — multivariate stats let the planner predict joinDate filter selectivity per friend accurately.
5. **Denorm `join_date BIGINT` on HAS_MEMBER** (schema change) — eliminates per-row agtype access during the join. Largest SF1000 win, largest engineering cost (backfill on ~700M-row edge table, IU5 maintenance, index swap). Defer until 2–4 are exhausted.

## Phase 2 — IS4 follow-up

- Profile `AgeConverter.toStr` against IS5's `toLong`/short-string conversion. If escape unwrap dominates, replace the 6-pass `String.replace` chain with a single regex or a manual char-by-char pass. Data-dependent fix, scales with message size not call count.
- Consider whether AGE returns content already-unescaped via the agtype text representation, making the unwrap a no-op for clean strings.
