# AGE Query Architectural Review

Reviewer persona: PostgreSQL/AGE + graph-DB architect. Scope: all 29 runtime query
files in `age/queries/`. Criteria: (1) natural Cypher/AGE idiom, (2) performance,
(3) correct AGE feature use, (4) **no SQL for graph operations** — Cypher does
traversal; SQL only aggregates/orders/unions/formats.

Verdict legend: **OK** clean · **FIX** rule violation, must change · **WATCH**
structurally slow but compliant, no rewrite available in AGE 1.6.

---

## FIX (action required)

### IC10 — graph operation performed in outer SQL  ← headline
`per_friend` CTE computes common-interest score by JOINing the AGE edge tables
`ldbc_snb."HAS_TAG"` ⋈ `ldbc_snb."HAS_INTEREST"` inside a `COUNT(...) FILTER`
(lines 57–62). That JOIN *is* the graph pattern
`(post)-[:HAS_TAG]->(tag)<-[:HAS_INTEREST]-(person)` — graph traversal in SQL.

- Violates the no-SQL-for-graph directive and §14 (the header's "graphid-keyed,
  therefore permitted" claim fails all three §14(b) gates: not GIN-bound, fires
  per (friend,post) *before* LIMIT, and is a boolean predicate not a scalar
  projection).
- Also the #1 latency hog: mean ~1490 ms, p99 ~18.5 s, max ~25.4 s.

**Fix** — move the tag overlap into the existing Cypher block. Both `EXISTS {}`
and `count(DISTINCT CASE WHEN … END)` are AGE-1.6 supported:
```cypher
OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
WITH p, friend, city,
     count(DISTINCT post) AS total,
     count(DISTINCT CASE
       WHEN EXISTS { MATCH (post)-[:HAS_TAG]->(:Tag)<-[:HAS_INTEREST]-(p) }
       THEN post END) AS common
RETURN friend.id, friend.firstName, friend.lastName,
       2*common - total AS score, friend.gender, city.name
ORDER BY score DESC, friend.id ASC LIMIT 10
```
Outer SQL drops to a thin format/cast wrapper (or none). Removes the violation and
should cut latency by letting AGE semi-join short-circuit instead of materializing
every (friend,post) pair for SQL. *Verify with EXPLAIN + benchmark — not assumed.*

**RESOLVED (2026-06-01).** Fix applied: tag-overlap moved into the Cypher block via
`EXISTS {}` semi-join; ORDER BY/LIMIT kept in outer SQL (AGE 1.6 rejects ORDER BY on
a Cypher RETURN alias — "could not find rte"). EXPLAIN confirms the overlap is a
SubPlan inside `cypher()` binding `idx_hastag_start`/`idx_hasinterest_start`, no outer
label-table JOIN. Validated byte-identical to the Neo4j oracle (LdbcQuery10 51/51).
50K benchmark before→after: mean 1844→1624 ms, **p99 17865→3881 ms (4.6×)**,
max 29482→23848 ms.

### IC1 — string sort missing codepoint collation
Outer `ORDER BY … friend_lastname::text ASC` (line 159) lacks `COLLATE "C"`. Per §6
the LDBC oracle sorts lastName in codepoint order; PG default `en_US.UTF-8` diverges
on case/punctuation. Secondary key after `distance`, so impact is narrow, but it is
a latent validation mismatch.
**Fix**: `friend_lastname::text COLLATE "C" ASC`. (IC4/IC6/IC11 already do this.)

**RESOLVED (2026-06-01).** Applied; validated byte-identical to the Neo4j oracle
(LdbcQuery1 50/50).

---

## WATCH (compliant; slow is structural, no AGE-1.6 rewrite)

- **IC9** ~21–35 s, **IC5** ~10–23 s — top of the latency board. Graph ops all in
  Cypher; cost is AGE #1000 (no predicate/LIMIT pushdown → full match-set
  materialized before ORDER/LIMIT). Currently disabled in the 50K run by design.
  These are the queries the project exists to surface upstream — do **not** mask
  with denorm.
- **IC12** ~1.8–42.8 s tail — runtime tag-id list can't bind a Cypher index
  (CLAUDE.md limit #3). Structural.
- **IC2** param-dependent tail (max ~21.6 s on high-degree persons) — date
  selectivity × KNOWS degree. Structural.
- **IC6** ~0.65 s mean — post-driven from the target Tag, scans all posts with that
  tag. A friend-driven rewrite *might* help at SF100+, but the header documents a
  real AGE chained-reverse-arrow bug that forces the explicit `WITH` segmentation.
  Leave until it reappears in SF100 profiling; then file the bug + consider a
  tag-pair denorm at IU6.
- **IC3** — country-driven `msgs` CTE materializes all messages in country during
  the window (SF100+ memory watch). Compliant: it JOINs two `cypher()` *result
  sets* on graphid, not raw label tables. Acceptable (mirrors the IC5 pattern).

---

## OK (no change)

- **IC2, IC4, IC5, IC7, IC8, IC11** — graph in Cypher, SQL only aggregates/orders.
  IC8 is the ideal pure-Cypher form. IC7 tie-break (§9) correct. IC4/IC11 collation
  correct.
- **IS1, IS3, IS4, IS5, IS7** — Cypher-only or Comment/Post `UNION ALL` hybrids
  (forced by no polymorphic Message label, §3). KNOWS directed (§11). IS3 header
  documents the bidirectional-storage duplicate-row caveat correctly.
- **IS6** — migrated to the natural `-[:REPLY_OF*1..]->` VLE Cypher form to surface
  AGE's VLE crash (§9); DISABLED in all configs pending the AGE VLE fix. Not pure SQL,
  not a precedent.
- **IS2** — Milestone-A placeholder by design (originalPost* fields pending VLE /
  Milestone B); author name via §14(b) GIN-bound LATERAL. Expected-incorrect in
  validation.
- **IU1–IU8** — all Cypher-only CREATE/UNWIND, minimal call counts per §11
  (IU1=1, IU4=1, IU5=1, IU6=1, IU7=2 with mandated MVCC split, IU8 bidirectional
  KNOWS). No side-table writes remain post-Milestone-A. Clean.
- **IC13/IC14** — return constants (no shortestPath/allShortestPaths). Intentional.

---

## Bottom line
One genuine rule violation (**IC10**) that is also the top hog, plus one one-line
collation fix (**IC1**). Everything else is either clean or slow-by-AGE-design and
must stay canonical to keep surfacing AGE weaknesses. No new denorm warranted.
