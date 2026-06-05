# IS5 (LdbcShortQuery5MessageCreator) — Infrequent benchmark crash

## Symptom

During benchmark runs (`mode=execute_benchmark`, e.g. via `driver/benchmark.sh
driver/benchmark-20k-5kwarmup.properties`), the workload occasionally crashes with:

```
java.lang.ClassCastException: class java.util.ArrayList cannot be cast to class
  org.ldbcouncil.snb.driver.workloads.interactive.LdbcShortQuery5MessageCreatorResult
  (java.util.ArrayList is in module java.base of loader 'bootstrap';
   org.ldbcouncil.snb.driver.workloads.interactive.LdbcShortQuery5MessageCreatorResult
   is in unnamed module of loader 'app')
  at org.ldbcouncil.snb.driver.workloads.interactive.LdbcSnbShortReadGenerator
     $ResultBufferReplenishFun.replenish(LdbcSnbShortReadGenerator.java:660)
  at org.ldbcouncil.snb.driver.workloads.interactive.LdbcSnbShortReadGenerator
     .nextOperation(LdbcSnbShortReadGenerator.java:484)
  at org.ldbcouncil.snb.driver.runtime.executor.ChildOperationExecutor
     .execute(ChildOperationExecutor.java:43)
```

Observed example: SF3 10K-op bench crashed at op ~511 (out of 10,000) on
`feature/age-implementation` against the local Docker AGE 1.6 / PG17.

## Where this is NOT

- **Not in our AGE-side code.** Our `IS5` handler is `ShortQuery5MessageCreator`
  in `age/src/main/java/.../AgeDb.java:560-588`, which extends
  `AgeSingletonOperationHandler`. That base handler at
  `AgeSingletonOperationHandler.java:37-72` reports a single
  `LdbcShortQuery5MessageCreatorResult` instance (or `null` for 0 rows) — never
  a list. `LdbcShortQuery5MessageCreatorResult` itself is a 3-field POJO
  (`personId`, `firstName`, `lastName`); it is not a `List`-subclass.

- **Not in the IS5 SQL.** `age/queries/interactive-short-2.sql`
  *(typo: short-5.sql)* uses `LIMIT 1` and the two-arm Cypher UNION ALL produces
  at most one row.

- **Not surfaced by validation runs.** `mode=validate_database` reads ops from
  the validation_params CSV sequentially and never invokes
  `LdbcSnbShortReadGenerator`. A clean 3000-op SF3 LDBC oracle slice run on
  2026-05-15 had 0 crashes; the same shape only crashes under bench mode where
  the short-read dissipation path is active.

## Where this IS

`LdbcSnbShortReadGenerator$ResultBufferReplenishFun.replenish(Operation op,
Object result)` is called by the framework's short-read dissipation path
after each operation. Bytecode inspection of the bundled LDBC driver classes
in `age/target/age-1.2.0-SNAPSHOT.jar` shows the method dispatches on
`op.type()`:

| Op type | `replenish` expects `result` to be… |
|---|---|
| 1 (IC1) | `List<LdbcQuery1Result>` |
| 2 (IC2) | `List<LdbcQuery2Result>` |
| 3 (IC3) | `List<LdbcQuery3Result>` |
| 7-12, 14 | `List<LdbcQuery<N>Result>` |
| 102 (IS2) | `List<LdbcShortQuery2PersonPostsResult>` |
| 103 (IS3) | `List<LdbcShortQuery3PersonFriendsResult>` |
| **105 (IS5)** | **single `LdbcShortQuery5MessageCreatorResult`** (NOT a list) |
| 106 (IS6) | single `LdbcShortQuery6MessageForumResult` (NOT a list) |
| 107 (IS7) | `List<LdbcShortQuery7MessageRepliesResult>` |

The relevant bytecode for type=105 is the unguarded singleton checkcast:

```
961: aload_2
962: checkcast LdbcShortQuery5MessageCreatorResult   // ← throws if result is a List
965: astore_3
966: aload_0
967: getfield personIdBuffer
970: aload_3
971: invokevirtual LdbcShortQuery5MessageCreatorResult.getPersonId():J
...
```

The crash means the result object passed to `replenish` for an IS5 op WAS a
`java.util.ArrayList`. Somewhere upstream — in `ChildOperationExecutor.execute`
or `nextOperation`'s caller — the framework substituted an `ArrayList` (likely
the result of some prior list-typed operation) for our singleton IS5 result.
This is a known shape of bug in the LDBC SNB driver framework's short-read
dissipation: the result buffer wiring confuses per-op result types.

It is NOT consistently reproducible — same workload, same params, two runs:
one crashes at op ~511, the other completes. Suspect race in the buffer
replenishment under multi-threaded execution.

## Why we are leaving it alone

- It is a driver-framework defect, not an AGE defect; fixing it requires
  upstream changes or a local patch to `LdbcSnbShortReadGenerator`.
- Benchmarks are expected to run as-is; we do not change the bench harness
  semantics to work around it (would invalidate cross-impl comparability).
- Validation against the LDBC SF3 oracle is unaffected — that path doesn't
  use `LdbcSnbShortReadGenerator` at all. Our correctness signal is clean.

## Reproduction artefacts

- Bench log demonstrating the crash:
  `age/results/bench-sf3-10k-iu-review-20260514-164351.log`
  (also: `age/results/bench-sf3-10k-iu-review-20260514-164328.log`,
  `age/results/bench-sf3-10k-*.log` from earlier runs).
- The error appears multiple times per bench because the framework attempts
  recovery, but the bench ultimately shuts down because the result buffer
  state is corrupted.
- Bytecode trace of `replenish` (re-generate with):
  ```
  javap -p -c -classpath age/target/age-1.2.0-SNAPSHOT.jar \
    'org.ldbcouncil.snb.driver.workloads.interactive.LdbcSnbShortReadGenerator$ResultBufferReplenishFun'
  ```

## If the crash becomes blocking later

1. Locate the LDBC SNB driver source matching the version in our JAR
   (`org.ldbcouncil.snb.driver` package, around `LdbcSnbShortReadGenerator
   .java:660`).
2. The fix is likely in the caller of `replenish` (probably
   `ChildOperationExecutor.execute`) — it is passing the wrong stored result
   for IS5/IS6 ops. Verify by adding an `instanceof` guard before the
   checkcast.
3. As a temporary workaround for affected bench runs, set
   `ldbc.snb.interactive.short_read_dissipation=0.0` in the bench properties.
   This disables the dissipation path entirely (short reads still run via the
   regular workload stream). Use only for diagnosis — production benchmark
   runs should keep the spec-mandated dissipation value (typically `0.2`).

## Owner

Unassigned. Tracked as task #4 in the optimization plan
(`age/optimization-plan-2026-05-15.md`).
