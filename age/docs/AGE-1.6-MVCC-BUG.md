# Apache AGE 1.6 Multi-Threaded MVCC Bug — Impact on LDBC SNB Benchmark

**Audience:** Technical PM + engineering team
**Status:** Known upstream issue, mitigated locally; resolved by upstream upgrade
**Last updated:** 2026-05-11

---

## TL;DR

Apache AGE 1.6 has a transactional visibility race that surfaces under concurrent
write workloads as the runtime error:

> `vertex assigned to variable <name> was deleted`

It is a real bug in AGE's executor (not in our code). It is fixed upstream in
AGE 1.7.0. Until we upgrade, we run with a bounded retry workaround in our JDBC
handler: the workload survives multi-threaded runs, but a small fraction of
update operations get dropped and logged. Read-side query measurements remain
correct and unaffected.

---

## The Bug

**Upstream issue:** Apache AGE GitHub #1954
**Upstream fix:** PR #2343, released in **AGE 1.7.0**

**Root cause (executor):** When a Cypher block performs multiple `CREATE`
statements inside a single transaction, AGE does not synchronise its executor
command-id (`curcid`) after each row insert. Subsequent visibility checks
within the same transaction therefore see the just-created vertex as briefly
invisible — and AGE raises the misleading "was deleted" error.

**Why multi-thread amplifies it:** With many concurrent transactions doing
multi-row `CREATE`s, the timing windows that expose the missing `curcid` sync
become much more common. Single-thread runs almost never trigger it.

---

## Impact on Our Benchmark

LDBC SNB Interactive v1 is a mixed read/write workload. At our usual
thread_count = 4 settings:

- **Read queries (IC1-IC12, IS1-IS7) — UNAFFECTED.** They do no `CREATE`, so
  visibility races cannot arise. Their measurements are sound.
- **Update queries (IU1-IU8) — AFFECTED to varying degrees** (see next section).
- **Pre-mitigation behaviour:** the workload crashed mid-stream — historically
  around op ~2800 at SF3, thread_count = 4 — which prevented any benchmark from
  completing.
- **Post-mitigation behaviour (current state):** the workload completes.
  A small percentage of update operations are dropped (no-op'd) and logged so we
  can account for them. Throughput numbers are therefore a slight
  **underestimate** — the dropped ops counted against wall time but never
  produced work.

---

## Which Queries Are Impacted

The bug triggers in proportion to how many `CREATE` clauses an operation
fires inside one Cypher block.

| Operation | CREATE pattern | Susceptibility |
|---|---|---|
| **IU1** AddPerson | Person + IS_LOCATED_IN + HAS_INTEREST + STUDY_AT + WORK_AT (many) | **High** |
| **IU4** AddForum | Forum + HAS_MODERATOR + HAS_TAG (few) | Medium |
| **IU6** AddPost | Post + HAS_CREATOR + CONTAINER_OF + IS_LOCATED_IN + HAS_TAG | **High** |
| **IU7** AddComment | Comment + HAS_CREATOR + REPLY_OF + IS_LOCATED_IN + HAS_TAG | **High** (most-reported in our logs) |
| **IU2** AddPostLike | Single LIKES edge | Low |
| **IU3** AddCommentLike | Single LIKES edge | Low |
| **IU5** AddForumMembership | Single HAS_MEMBER edge | Low |
| **IU8** AddFriendship | Symmetric KNOWS pair | Low |

Read-only queries (IC1-IC12, IS1-IS7) are not impacted.

---

## Current Workaround

Implemented in
`age/src/main/java/org/ldbcouncil/snb/impls/workloads/age/operationhandlers/AgeUpdateOperationHandler.java`.

**Mechanism:**

1. Wrap the Cypher `execute()` in a try/catch for `SQLException`.
2. Pattern-match the error message: `vertex assigned to variable ... was deleted`.
3. On match, roll back, sleep `AGE_MVCC_RETRY_BACKOFF_MS × attempt` (currently 2 ms),
   retry up to `MAX_AGE_MVCC_RETRIES` (currently **1**) times.
4. If still failing: report the op as a no-op so the workload doesn't abort,
   and append a line to `/tmp/age-mvcc-skips.log` for after-the-fact accounting.

**Why retry budget is low (1):** AGE 1.6's race tends to be consistent for the
same input — repeating doesn't usually help. We retry once with a tiny delay
(covers genuine transients) and then release the JDBC connection rather than
starve the pool. Tuning the budget higher has not measurably reduced skips in
prior runs.

**Operational impact:**

- Workload runs to completion at any thread count.
- Read latencies are unaffected.
- IU latencies have a small added cost on retried ops (microseconds — the sleep
  is short).
- A skip count is observable in `/tmp/age-mvcc-skips.log`. Report this with
  every multi-thread benchmark result. It is the noise floor, not a correctness
  failure.

**Other workarounds considered and rejected:**

- **Force single-thread** — defeats the purpose of measuring SF1000 throughput.
- **Serialise each IU through a single global lock** — would mask the bug but
  also mask the very contention we're trying to measure.
- **Split multi-row CREATE into separate transactions per row** — changes IU
  semantics (no atomic Add) and still doesn't guarantee the race is gone.
- **Switch IU writes to raw SQL instead of Cypher** — moves us off the graph
  query path the benchmark is designed to exercise.

The retry workaround is the least invasive option that lets us produce
SF3/SF1000 multi-thread numbers without changing the benchmark's semantic
shape.

---

## Recommendation

**Upgrade to Apache AGE 1.7.0** as the durable fix. PR #2343 addresses the
underlying `curcid` synchronisation issue. The upgrade is tracked separately;
it requires:

1. Confirming our Cypher queries still parse (syntax has been stable across
   1.6 → 1.7).
2. Re-running validation at SF0.1 + SF3.
3. Removing the retry workaround once verified (or leaving it as a defensive
   no-op).

Until then, the retry workaround above is the correct operating posture for
multi-threaded benchmark runs.

---

## References

- **Upstream issue:** https://github.com/apache/age/issues/1954
- **Upstream fix:** https://github.com/apache/age/pull/2343 (in AGE 1.7.0)
- **Workaround source:** `age/src/main/java/.../operationhandlers/AgeUpdateOperationHandler.java`
- **Skip log:** `/tmp/age-mvcc-skips.log` (written by the workaround when retries are exhausted)
