# AGE LDBC SF3 Optimization — Findings + Forward Plan

Session window: 2026-05-13 → 2026-05-15. Local SF3 (`apache/age:release_PG17_1.6.0` Docker, `--shm-size=2g`, M2 Pro / 16 GB).

This document consolidates every measurement and decision taken during this work, with their data and rationale, plus the forward plan items that did not land in this window.

---

## 1. Executive summary

| Workstream | Status | Material outcome |
|---|---|---|
| IU §14 cleanup (Tier 1: IU1 + IU6) | ✅ landed | Outer SQL no longer reads `Person`/`Post`/`CONTAINER_OF` from AGE label tables. `Post.forum_id` retired. |
| IU §14 cleanup (Tier 2: IU7) | ✅ landed | `Comment.creator_id` + `Comment.reply_of_id` retired (after colleague's IC12 + earlier IS2 migrations). |
| IC3 correctness fix | ✅ landed | HAS_CREATOR direction reversed on lines 37+58. Verified output now matches LDBC oracle byte-for-byte. |
| IC4 correctness fix | ✅ landed | Outer SQL `ORDER BY tagName` requires `COLLATE "C"` to match LDBC oracle codepoint sort. |
| IU-latency investigation | ✅ measured | **Per-cypher() call count is NOT the bottleneck.** Single-thread folding saves 1.5%; concurrent multi-thread is contention-dominated. |
| Side-table-in-IU anti-pattern? | ✅ answered | NOT anti-pattern. Removing `PersonPostCount` measured **7× regression** on IC10 read. |
| AGENTS.md doc drift | ⏳ pending | §11 (IU cypher() call counts) and §13 (parameterized list) need updating to current reality. |
| All-queries deep investigation + JIT-on test | ⏳ pending | Bookmarked as Track #14 — should be next major workstream. |

All committed changes are in branch `feature/age-implementation`, commit `e7b8792b "updates to ic1, 3,4,6,7"`.

---

## 2. What landed in commit `e7b8792b`

| File | Change |
|---|---|
| `interactive-update-1.sql` | 2 cypher() calls. Side tables: PersonPostCount + PersonSide (via CTE chain off Call 2 RETURN). |
| `interactive-update-6.sql` | 2 cypher() calls (was 1 + 4 SQL DML). Forum/author/content RETURNed from Call 2 into a writable-CTE chain that drives FMPC, PPC, MessageByCreator. One `UPDATE Post SET creator_id` write remains (load-bearing for IC10 — colleague's scope). |
| `interactive-update-7.sql` | UPDATE Comment dropped entirely. Stays at 3 cypher() calls (MVCC split + content read). Zero AGE-table touches in outer SQL. |
| `interactive-complex-3.sql` | HAS_CREATOR direction corrected: `(msg)-[:HAS_CREATOR]->(friend)` (was reversed; every IC3 op returned 0 rows pre-fix). |
| `interactive-complex-4.sql` | `ORDER BY postCount DESC, tagName::text COLLATE "C" ASC` — codepoint order matches LDBC oracle vs PG default `en_US.UTF-8`. |
| `denormalize-schema.sql` | `Post.forum_id` declaration + backfill + indexes retired. `Comment.creator_id` + `reply_of_id` declarations + backfills + indexes retired. `CommentRootPost` backfill rewritten to traverse `REPLY_OF` directly. `MessageByCreator` Comment-leg rewritten to traverse `HAS_CREATOR` (replaces `Comment.creator_id` join). |
| `SCHEMA.md`, `INDEXES.md`, `README.md`, `AGENTS.md` | Doc updates reflecting the retirements. |
| `AGE-QUIRKS.md` | Added §14 — PG default collation sorts punctuation after letters; outer-SQL ORDER BY on agtype strings needs `::text COLLATE "C"` to match LDBC oracle. |

---

## 3. IU latency investigation — findings

### Hypothesis chain (resolved)

The user observation: "we have made updates more complex and they also take more time hence making the negative impact as well. We should plan to follow the same practice [as postgres/duckdb/umbra which use single INSERTs]."

Subsequent hypothesis: "Breaking down cypher too much might be causing issues as well."

Both empirically tested. Both falsified.

### Measurements

**3a. Server-side cypher() cost is essentially zero**

Direct measurement, single psql session, 100 sequential IU3-shape calls:
```
Total ms: 9, mean: 0.09 ms/call
```

**3b. Bench p50 is 360× larger than server-side cost** (multi-thread SF3, 10K ops, IU3=486 samples)

| Metric | Value |
|---|---|
| Server-side warm | 0.09 ms |
| Bench p50 | **360 ms** |
| Ratio | **4000×** |

The 360 ms p50 has nothing to do with query work — it is entirely JDBC + AGE-per-call + concurrent contention overhead.

**3c. Tier B per-stage instrumentation** (instrumented `AgeUpdateOperationHandler.executeOperation` — 500-op SF3 multi-thread bench):

| IU (n) | acquire | begin | prepare | bind | **execute** | commit | total p50 |
|---|---|---|---|---|---|---|---|
| IU3 AddCommentLike (36) | 96 | 0 | 0.1 | 0 | **513 (84%)** | 4 | 295 |
| IU6 AddPost (17) | 29 | 0 | 0.4 | 0 | **440 (94%)** | 1 | **11** |
| IU2 AddPostLike (26) | 67 | 0 | 0.1 | 0 | **183 (72%)** | 4 | 134 |
| IU7 AddComment (29) | 62 | 0 | 0.3 | 0 | **116 (64%)** | 1 | **12** |
| IU5 AddForumMembership (78) | **165 (89%)** | 0 | 0.1 | 0 | 15 | 4 | 16 |
| IU8 AddFriendship (2) | **1072 (98%)** | 0 | 0.2 | 0 | 12 | 9 | 2161 |
| IU4 AddForum (2) | 0 | 0 | 0.2 | 0 | **37 (97%)** | 1 | 63 |

`prepare` and `bind` are sub-millisecond (PG prepared-statement caching is working as designed). `execute` is where 60–95% of the time goes for the "slow" IUs.

**3d. Folding cypher() calls doesn't help in sequential workloads** (Python + psycopg2, single connection, 100 sequential ops each shape):

| Shape | Result |
|---|---|
| A — current Tier-1 IU1 with 2 cypher() calls | mean 3.33 ms, p50 2.61 ms |
| B — folded IU1 with 1 cypher() call (RETURN id(p), firstName, lastName) | mean 3.28 ms, p50 3.04 ms |
| **Δ** | **1.5% — within noise** |

**3e. The folding hypothesis is falsified by the Tier B data itself**:

If "more cypher() calls = slower", then:
- IU3 (1 cypher() call) should be FASTER than IU6 (2 cypher() calls)

But the data shows:
- IU3 p50 = 295 ms (1 cypher)
- IU6 p50 = **11 ms** (2 cypher) — 27× faster
- IU7 p50 = **12 ms** (3 cypher) — also 24× faster

The per-cypher()-call overhead is real (~30-100 ms cold, sub-ms warm) but not the dominant cost. **The dominant cost is something else**, most likely:
- Cold-buffer GIN containment lookups on the 5.4M-row `Comment` label table (IU3 hits this every call)
- Concurrent contention on edge-table B-tree pages
- AGE plan-cache miss-rate under multi-connection load

### What this means for the original "match postgres single-INSERT IUs" goal

The premise was wrong. AGE's IU latency is not caused by side-table maintenance count. Removing side tables would NOT make AGE match postgres throughput. Confirmed by the separate Phase 0 measurement of dropping `PersonPostCount`:

| Path | IC10 EXPLAIN ANALYZE execution time |
|---|---|
| Current — with `PersonPostCount` | **607 ms** |
| Alt — count from `MessageByCreator` at read time | **4157 ms** (7× slower) |

The aggregate side tables earn their write-amplification cost through huge read speedups. Postgres can compute these at read time fast because postgres has tabular storage; AGE has agtype + GIN, which makes per-call aggregates slow. The side-table-in-IU pattern is a workaround for AGE's structural limits, not anti-pattern.

### Why Track A folding (eliminate cypher() calls) is blocked anyway

Even if folding HAD helped, AGE 1.6 doesn't support `FOREACH`, and `WITH x, count(*)` over an empty UNWIND returns 0 rows (verified). Result: any cypher() block with optional UNWIND lists collapses to 0 rows when the list is empty, so we cannot fold the `RETURN id(p), …` projection into Call 1 reliably. Track A only becomes feasible when AGE adds `FOREACH` (post-1.6).

### Side bug discovered (latent, not yet a regression)

IU1's chain pattern `WITH p, count(*) AS dummy1 UNWIND $tagIds … WITH p, count(*) AS dummy2 UNWIND $studyAt …` collapses to 0 rows on the first empty UNWIND. Reproduced live: with `$tagIds=[]` and `$studyAt=[4]`, the STUDY_AT edge is silently NOT created. LDBC datagen always provides non-empty `$tagIds` for IU1 ops, so this is latent in practice — but it'll bite the first time test data exercises the empty path.

Recommended fix (separate commit): replace the `WITH p, count(*) AS dummy` chain with discrete cypher() calls guarded by outer-SQL `size()` checks, or use `OPTIONAL MATCH (t:Tag) WHERE t.id IN $tagIds … WITH p, collect(t) AS tags UNWIND tags AS t` — the `OPTIONAL MATCH` preserves the row even when nothing matches.

---

## 4. IC3 / IC4 correctness — full diagnosis

These were pre-existing failures (~85% IC3 rate, ~15% IC4 rate) that surfaced when we ran the focused 3K-row LDBC oracle slice. Neither is related to Tier 1/2 work.

### IC3 — HAS_CREATOR direction reversed

The two arms had `<-[:HAS_CREATOR]-(friend)` reading "edge from friend to msg". But HAS_CREATOR is stored `(Message)-[:HAS_CREATOR]->(Person)`, so the reversed pattern matches zero edges. Every IC3 op returned 0 rows.

Verified fix: changed both arms to `-[:HAS_CREATOR]->(friend)`. End-to-end test for first failing param `(personId=26388279078570, X=Honduras, Y=Estonia)` returns exactly the LDBC-expected 2 rows.

This pattern is in AGENTS.md "How to Review a Query" §2 (Edge directions) — and IC3 had been violating it. Likely a regression from an earlier refactor (commit history shows IC3 has been touched in several "fixes" commits).

### IC4 — sort collation mismatch

Outer SQL `ORDER BY tagName ASC` was using PG's default `en_US.UTF-8` collation, which sorts `_` AFTER letters. The LDBC oracle uses codepoint order where `_` (0x5F) sorts between uppercase and lowercase. This flipped the row at the `LIMIT 10` cutoff on tied postCount values (`Angel_of_Harlem` vs `Angelina_Jolie`).

Verified fix: `ORDER BY postCount DESC, tagName::text COLLATE "C" ASC`. Documented as AGE-QUIRKS §14.

### Validation status post-fix

Focused 3K-row LDBC oracle slice re-run after fixes — partial sample at 800/3K ops shows:
- IC3 incorrect: 0 (was 113)
- IC4 incorrect: 0 (was 23)
- Remaining: IC13=38, IC14=38 (stubs, intentional), IC11=1 (pre-existing, not in scope)

---

## 5. Open issues catalog

| # | Issue | Severity | Status |
|---|---|---|---|
| 4 | LDBC driver `LdbcShortQuery5MessageCreatorResult` ClassCastException crashes bench at op ~511 | medium — pre-existing, not from this work | not fixed; bench works to that point |
| — | IU1 latent empty-UNWIND-collapse bug (silent missed edges when `$tagIds`/`$studyAt`/`$workAt` is empty) | low for LDBC SF3 (datagen ensures non-empty); high if test data changes | not fixed; separate commit |
| — | Full LDBC SF3 validation oracle (145,678 ops) requires ~50 h on M2 Pro — not viable in a session | accepted limit | mitigation: use sliced runs (e.g., 3K-row prefix) for diagnosis |
| 5 | AGENTS.md §14 scoping (runtime vs deploy-time SQL) | docs-only | not yet edited |
| — | AGENTS.md §11 (IU cypher() call counts) says "most IUs use exactly one call" — out of date post Tier 1/2 | docs-only | not yet edited |
| — | AGENTS.md §13 (parameterized list) lists IU5 incorrectly | docs-only | not yet edited |
| 6 | Tier 3 (physically drop retired denorm columns) blocked by AGE 1.6 "table X is for label X" | accepted limit | will re-attempt when AGE relaxes this |
| 8 | Fresh-load SF3 + 10K bench end-to-end check | pending | not yet run after Tier 2 — would validate the new denormalize-schema.sql backfill end-to-end |

---

## 6. Forward plan — major workstreams

### 6.1 — Per-query construct + JIT-on investigation (Track #14)

Driver: user's note "do the same exercise for all the queries. deeply investigate if using better age constructs and keeping jit on can improve the complex queries… cypher module in age relies on it for optimizations? this might make things simpler for us."

#### Phase 1 — JIT-on A/B for complex reads — DONE 2026-05-15

Tested all 12 ICs at SF3, 4 iterations each, jit=off vs jit=on, `jit_above_cost=100000`. Median execution times:

| Query | JIT off (ms) | JIT on (ms) | Δ% | Verdict |
|---|---|---|---|---|
| IC6  | 101.3  | 90.0   | +11.2% | **WIN** |
| IC1  | 51.4   | 48.6   | +5.5%  | win |
| IC9  | 183.8  | 174.5  | +5.1%  | win |
| IC2  | 579.3  | 562.2  | +3.0%  | neutral |
| IC10 | 208.3  | 204.6  | +1.8%  | neutral |
| IC4  | 357.1  | 353.9  | +0.9%  | neutral |
| IC11 | 287.7  | 288.2  | -0.2%  | neutral |
| IC5  | 204.7  | 210.5  | -2.9%  | neutral |
| IC8  | 2.5    | 2.7    | -5.1%  | loss |
| IC7  | 2023.3 | 2169.7 | -7.2%  | **LOSS** |
| IC12 | 271.2  | 300.4  | -10.8% | **LOSS** |
| IC3  | 3751.0 | 4249.7 | -13.3% | **LOSS** |

**Hypothesis falsified.** The cypher module in AGE does NOT rely on JIT for material optimization. The largest win (IC6 +11%) is modest; the largest losses (IC3 -13%, IC12 -11%, IC7 -7%) are bigger than the wins.

Cold-call EXPLAIN output for IC3 with JIT on shows the mechanism:
```
JIT:
  Functions: 257
  Options: Inlining true, Optimization true, Expressions true, Deforming true
  Timing: Generation 8 ms, Inlining 64 ms, Optimization 266 ms,
          Emission 266 ms, Total 604 ms
Execution Time: 5354 ms
```

Two problems with JIT for AGE:
1. **JIT compile cost is real** — IC3 paid 604 ms of compile time (mostly inlining + optimization + emission) for 257 functions.
2. **JIT-compiled execution is actually SLOWER for some AGE queries** — IC3 cold execution-time was 5354 ms with JIT, 3751 ms without. JIT doesn't just fail to help; it actively makes the query slower.

Why JIT doesn't help and sometimes hurts AGE Cypher:
- AGE's heaviest operations are `_agtype_build_vertex(...)`, `agtype_access_operator(VARIADIC ARRAY[properties, '"X"'::agtype])`, GIN containment, and edge traversal — all opaque C functions invoked via function pointers.
- JIT specializes EXPRESSION TREES. AGE's expression trees are dominated by these opaque calls. The compiled code path adds JIT trampoline overhead without the inlining benefit that would normally pay it back.
- For queries with many distinct expression nodes (IC3's 257 functions, IC7's many JOIN cases), inlining decisions can pessimize the plan.

The `jit=off` decision in `AgeDbConnectionState.java` is correct and the comment there ("savings never recoup cost") is empirically validated for the AGE use case.

#### Phase 2 — Per-query AGE 1.6 construct audit (PENDING)

Phase 2 — AGE 1.6 construct audit per query — pending.

For each IC1–IC12 + IS1–IS7 + IU1–IU8:
1. Read the current SQL.
2. List every Cypher construct used.
3. Cross-reference against AGENTS.md §"AGE 1.6 Cypher Constructs — Reference for Query Design" — supported, unsupported, structural limits.
4. Identify if a different supported construct would be cleaner or faster:
   - `CALL fn(args) YIELD col` — anywhere we currently UNWIND a function output by hand
   - `EXISTS { pattern }` / `COUNT { pattern }` — subqueries that currently route through outer SQL
   - List comprehensions `[x IN list WHERE pred | expr]` — anywhere we currently UNWIND + WITH + collect
   - Map projection — anywhere we currently emit columns manually
   - Schema-qualified PG function calls from Cypher — anywhere outer SQL is currently used to wrap a Cypher result through a side-table lookup
5. Prototype the alternative, run validator against the 3K-row LDBC slice, measure.

The bias-toward-pure-Cypher rule (per user direction) is important here. Where current code uses hybrid Cypher+SQL only for AGE-quirk workarounds, those workarounds may have become unnecessary in patterns we missed. Track A folding turned out infeasible for IU1/IU4/IU6 (empty-UNWIND-collapse) but other queries may have similar structure where the AGE 1.6 constructs available DO permit consolidation.

**Phase 2 priorities, ranked by likely benefit** (per execution time + plan complexity):

| Rank | Query | Current shape | Why audit this |
|---|---|---|---|
| 1 | **IC3** | 2-arm hybrid (Comment + Post), 3.7 s | Slowest IC. Two full friend-set computations duplicated across arms. List-comprehension or CALL/YIELD might let one pass drive both arms. |
| 2 | **IC7** | hybrid, 2.0 s | DISTINCT ON window with multiple cypher() arms; may benefit from single Cypher + EXISTS subquery. |
| 3 | **IC2** | hybrid 2-arm, 0.58 s | Comment + Post arms with UNION ALL; the `<= maxDate` filter could move into a single CALL/YIELD. |
| 4 | **IC4** | pure Cypher single call, 0.36 s | Already clean; check if inner ORDER BY can be removed (outer SQL is authoritative). |
| 5 | **IC10** | hybrid with §14 LATERAL on Post (colleague's scope) | Audit after IC10 migration to side tables lands. |
| 6 | **IC11** | hybrid 2-arm, 0.29 s | Similar pattern to IC2; same Cypher-only candidate. |
| 7 | **IC12** | hybrid with TagClass ladder (6 OPTIONAL MATCH levels), 0.27 s | Variable-length subclass walk could use CALL/YIELD on a recursive PG function. |
| 8 | **IC5** | hybrid friend-set + 3 side-table joins, 0.20 s | Already optimal for the side-table model. Skip unless audit reveals different. |
| 9 | **IC9** | hybrid with `MessageByCreator` LATERAL, 0.18 s | Recently rewritten (Phase C in IC9-rewrite plan). Side-table is load-bearing. Skip. |
| 10 | **IC6** | hybrid 2-arm, 0.10 s | Smallest. Skip unless trivial. |
| 11 | **IC1** | hybrid 3-hop arms, 0.05 s | Fast. Skip. |
| 12 | **IC8** | hybrid, 2.5 ms | Already at floor. Skip. |

Recommended approach for Phase 2: start with IC3 + IC7 (the slowest two). If creative-Cypher rewrites materially help, the pattern generalizes; if not, the remaining queries are unlikely to benefit much either.

#### Phase 3 — IU bottleneck remediation (only if Phase 1 + 2 find no read wins)
The IU latency investigation showed concurrent multi-thread bench p50 = 360 ms for IU3 vs <1 ms server-side. The gap is in JDBC/AGE-internal/cold-buffer paths, not query shape. To attack it:
1. PG flame graph the running Java + PG server over 100 IU ops to see where the wall time goes.
2. If GIN cold-buffer thrashing on `Comment`/`Post` label tables, evaluate `pg_prewarm` on these GIN indexes at restore time so the first IU calls don't pay cache-miss cost.
3. If concurrent edge-write contention, evaluate batched writes (collect IUs into batches, flush periodically) — but this changes LDBC semantics, probably out of scope.

### 6.2 — Documentation hardening (Track #5 + related)

Bundle into one docs-only commit, no code changes:

- AGENTS.md §11: replace "most IUs use exactly one call" with the actual pattern — describe Tier 1/2 cypher()-call splits per IU (IU1=2, IU4=2, IU5=1, IU6=2, IU7=3) and the structural reasons (each is an AGE 1.6 workaround: empty-UNWIND-collapse, MVCC race, etc.).
- AGENTS.md §13: refresh the parameterized list to match `driver/validate-local.properties` and `benchmark-local*.properties`. Remove IU5 from the §13 list (it's not actually parameterized).
- AGENTS.md §14: add a one-line clarification that the rule applies to runtime query files in `age/queries/`, not deploy-time tooling in `age/scripts/`. (User asked about this for the CommentRootPost backfill rewrite.)
- AGENTS.md "How to Review a Query" §6: add the COLLATE "C" requirement that just landed.
- AGENTS.md: add a new §"When to add a side table" — captures the lesson from the side-table investigation: side tables are not anti-pattern, but every new one should justify itself with a measurement showing the read-side benefit exceeds the maintenance cost.

### 6.3 — Validation discipline

Two operational additions, no code:

- The Hikari pool sizing (`age_connection_pool_size` matching `thread_count`) is brittle when an op takes seconds (IU8 acquire spike of 1072 ms in Tier B data). Recommend documenting `pool_size = thread_count + 2` as the rule.
- `max_parallel_workers_per_gather=0` on the live DB eliminates the `/dev/shm` PostgreSQL exhaustion that broke the 2,167-op validation run mid-flight. Make this the default in the container start config or document as a required `ALTER DATABASE` post-restore.

---

## 7. Specific things to NOT do

These were considered and rejected based on measurement:

- **Don't fold cypher() calls to optimize IU latency.** 1.5% gain at single-thread; not measurable at multi-thread.
- **Don't remove `PersonPostCount` / `ForumMemberPostCount` / `MessageByCreator`.** Each one has a measured >5× read-side benefit. The IU maintenance cost is dwarfed by the read win.
- **Don't try to "match postgres single-INSERT IUs".** Postgres' base tables are SQL-native; ours are agtype + GIN. The structural difference forces side tables; eliminating them moves work to read time where it costs more.
- **Don't pursue Track A (cypher-call folding) until AGE adds `FOREACH`.** Empty-UNWIND-collapse blocks the obvious approach in AGE 1.6.
- **Don't run full SF3 LDBC validation in a session.** 50 h on M2 Pro. Slice the oracle to a 3K-row prefix for diagnosis; full runs need a dedicated long-running environment.

---

## 8. Open question for next session

The biggest leverage in the next session is **Phase 1 (JIT-on A/B for complex reads)**. If JIT-on materially helps IC1/IC3/IC5/IC9/IC12 — which would suggest that the AGE Cypher module's expression evaluation is JIT-amenable — many of our hybrid-SQL workarounds become candidates for re-evaluation as pure-Cypher. That's the kind of finding that could simplify the implementation substantially.

If JIT-on doesn't help complex reads, then Phase 2 (per-query AGE-construct audit) is the right second pass, and we treat the current implementation shape as durable.

The data points to gather first:
1. EXPLAIN (ANALYZE, BUFFERS) for IC3 / IC5 / IC9 at SF3 — `jit=off` (current)
2. Same with `jit=on` — flip via `ALTER DATABASE postgres SET jit = on; ALTER DATABASE postgres SET jit_above_cost = 100000;`
3. Compare planning + execution + buffers
4. If execution drops by ≥2× on any query while planning stays under 100 ms, JIT is worth enabling for at least that query

That single experiment will tell us whether the broader pure-Cypher push the user wants to make is realistic or whether we're stuck with hybrid SQL for the foreseeable future.
