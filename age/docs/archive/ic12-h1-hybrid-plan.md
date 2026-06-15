# IC12 Hybrid Hash-IN Optimization Plan (H1)

**Date**: 2026-05-14
**Status**: Planned (not yet implemented)
**Companion**: `ic12-optimization-bottlenecks.md` Phases 1–7

---

## Context

IC12 ("Expert Search") currently spends ~51s at SF3 for broad tag classes (e.g., `Person`),
projecting to **hours** at SF1000. The dominant cost is a single operator in AGE 1.6:
`agtype_in_operator` does a row-by-row linear scan of the `validTagIds` array. For
Person/broad, that is 5,085 elements × 743K post-tag rows = **3.78B comparisons** in one
Join Filter (measured ~22s of the 51s total). The remaining ~18s is a GroupAggregate
sort that AGE compiles to reconstruct the full `friend` vertex blob in the GROUP KEY —
confirmed in EXPLAIN.

Phase 7 attempts (this session) were all neutralised by AGE's compilation or caused
planner instability:
- `WITH friend.id AS personId` does not change the compiled GROUP KEY — AGE still
  emits `_agtype_build_vertex(friend.id, ..., friend.properties)`.
- `id(comment)` compiles to `age_id(_agtype_build_vertex(comment...))` — same vertex
  rebuild.
- Inline `(tag)-[:HAS_TYPE]->(tc)` flipped the HAS_TAG join from Nested Loop + Index
  Scan to Hash Join, causing a 7.8s regression on narrow tag classes.

The correctness fix (`id(tag)` → `tag.id`) has been applied and is the only genuine
improvement this session. Performance is still at the Phase 5 baseline.

The path forward is to leave the graph traversal in Cypher (per AGENTS.md Implementation
Style) but move the IN check out of Cypher entirely and let PostgreSQL handle it as a
hash semi-join. This is the proven hybrid pattern from IC5.

---

## Recommended Approach — H1: Hybrid Hash-IN

Two `cypher()` calls connected via PostgreSQL CTEs. Outer SQL handles the IN check
(as a hash semi-join), GROUP BY aggregation, and final ORDER BY / LIMIT.
**Zero schema change. Zero side tables. Zero IU maintenance work.**

### SQL skeleton (final form; types and ordering verified against `interactive-complex-10.sql`)

```sql
WITH valid_tag_ids AS MATERIALIZED (
  SELECT (tid::text::bigint) AS tag_biz_id
  FROM cypher('$graphName', $$
    MATCH (base:TagClass {name: $tagClassName})
    OPTIONAL MATCH (d1:TagClass)-[:IS_SUBCLASS_OF]->(base)
    OPTIONAL MATCH (d2:TagClass)-[:IS_SUBCLASS_OF]->(d1)
    OPTIONAL MATCH (d3:TagClass)-[:IS_SUBCLASS_OF]->(d2)
    OPTIONAL MATCH (d4:TagClass)-[:IS_SUBCLASS_OF]->(d3)
    OPTIONAL MATCH (d5:TagClass)-[:IS_SUBCLASS_OF]->(d4)
    OPTIONAL MATCH (d6:TagClass)-[:IS_SUBCLASS_OF]->(d5)
    UNWIND [base.id, d1.id, d2.id, d3.id, d4.id, d5.id, d6.id] AS classId
    WITH classId WHERE classId IS NOT NULL
    WITH collect(DISTINCT classId) AS validClassIds
    MATCH (tc:TagClass) WHERE tc.id IN validClassIds
    WITH tc
    MATCH (tag:Tag)-[:HAS_TYPE]->(tc)
    RETURN tag.id AS tid
  $$) AS x(tid agtype)
),
traversal AS (
  SELECT
    (friend_id::text::bigint)               AS friend_biz_id,
    friend_fn::text                         AS friend_fn_t,
    friend_ln::text                         AS friend_ln_t,
    (comment_gid::text)::ag_catalog.graphid AS comment_gid_s,
    (tag_id::text::bigint)                  AS tag_biz_id,
    tag_name::text                          AS tag_name_t
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WITH friend
    MATCH (friend)<-[:HAS_CREATOR]-(comment:Comment)
    WITH friend, comment
    MATCH (comment)-[:REPLY_OF]->(post:Post)
    WITH friend, comment, post
    MATCH (post)-[:HAS_TAG]->(tag:Tag)
    RETURN friend.id, friend.firstName, friend.lastName,
           id(comment), tag.id, tag.name
  $$) AS x(friend_id agtype, friend_fn agtype, friend_ln agtype,
            comment_gid agtype, tag_id agtype, tag_name agtype)
),
agg AS (
  SELECT
    t.friend_biz_id, t.friend_fn_t, t.friend_ln_t,
    COUNT(DISTINCT t.comment_gid_s) AS reply_count,
    ('[' || string_agg(DISTINCT '"' || t.tag_name_t || '"', ','
                       ORDER BY '"' || t.tag_name_t || '"') || ']') AS tag_names_json
  FROM traversal t
  WHERE EXISTS (SELECT 1 FROM valid_tag_ids v WHERE v.tag_biz_id = t.tag_biz_id)
  GROUP BY t.friend_biz_id, t.friend_fn_t, t.friend_ln_t
  ORDER BY reply_count DESC, t.friend_biz_id ASC
  LIMIT 20
)
SELECT
  friend_biz_id::ag_catalog.agtype                AS personId,
  ('"' || friend_fn_t || '"')::ag_catalog.agtype  AS personFirstName,
  ('"' || friend_ln_t || '"')::ag_catalog.agtype  AS personLastName,
  tag_names_json::ag_catalog.agtype               AS tagNames,
  reply_count::ag_catalog.agtype                  AS replyCount
FROM agg
ORDER BY reply_count DESC, friend_biz_id ASC;
```

### Why this works

- `EXISTS (... WHERE v.tag_biz_id = t.tag_biz_id)` with `tag_biz_id` typed as `bigint`
  on both sides → PostgreSQL Hash Semi Join, **O(n+m) instead of O(n×m)**. Build side
  is 5,085 rows of `bigint` (~80 KB hash) — fits trivially in work_mem.
- The GROUP BY operates on plain `bigint`/`text` columns, not on AGE-reconstructed
  vertex blobs. The 18s sort cost should drop dramatically.
- `MATERIALIZED` on `valid_tag_ids` forces the Cypher CTE to be evaluated exactly once.
  Without it PG≥12 can inline and re-execute per outer row.
- Two `cypher(` occurrences → JDBC handler will write two `?` placeholders and bind the
  SAME agtype JSON to both (IU7's mechanism, confirmed in
  `AgeListOperationHandler.executeOperation()`). Each Cypher block uses only its
  relevant `$paramName`.
- Outer SQL touches only the two cypher() CTE results — no `JOIN ldbc_snb."HAS_TAG"`
  etc. → fully compliant with **AGENTS.md §14**.

### Expected impact

| TagClass | SF3 today | SF3 target | SF10 target | SF1000 estimate |
|---|---|---|---|---|
| BasketballPlayer | ~7s | <2s | <3s | <30s |
| MusicalArtist | ~18s | <5s | <8s | <60s |
| Person (broad) | ~51s | <8s | <15s | 60–120s |

---

## Critical Files

| Path | Action |
|---|---|
| `age/queries/interactive-complex-12.sql` | **Primary rewrite** to H1 skeleton above |
| `age/queries/interactive-complex-5.sql` | Reference pattern (compliant hybrid: cypher → side-table joins → SQL aggregation). Copy: `MATERIALIZED` CTE, `(gid::text)::ag_catalog.graphid` cast |
| `age/queries/interactive-complex-10.sql` | Reference for agtype↔SQL conversions: `(friend_id::text::bigint)`, `('"' \|\| text_t \|\| '"')::ag_catalog.agtype` round-trip |
| `age/queries/interactive-update-7.sql` | Reference for two-cypher-call pattern — proves the JDBC handler binds the same JSON to both `?` placeholders |
| `age/queries/AGENTS.md` | Compliance constraints (§13 cypher( count, §14 no AGE table reads in outer SQL) |
| `age/ic12-optimization-bottlenecks.md` | Append **Phase 8** documenting the H1 design, before/after timings, S1 fallback |
| `age/scripts/ic12-quicktest.sql` | Update PREPARE to wrap the new two-cypher form |
| `age/scripts/ic12-sf10-index-check.sql` | Run on SF10 before measuring (independent prerequisite) |
| `age/driver/benchmark.properties` | No change — `Query12` is already in `age_parameterized_queries` |

**Reference materials to NOT copy**:
- `interactive-complex-10.sql` outer-SQL JOINs to `ldbc_snb."Post"`/`."HAS_TAG"`/`."HAS_INTEREST"` violate §14 (legacy, pending migration per the 2026-05-13 directive). IC12 must follow IC5's pattern instead.

---

## Implementation Sequence

1. **Run `age/scripts/ic12-sf10-index-check.sql` on the SF10 server** (independent
   prerequisite, already written, idempotent). Confirms `idx_person_graphid` exists and
   Person stats are fresh; resolves the Parallel Seq Scan + 50M-row cross join seen in
   the SF10 EXPLAIN. Without this, SF10 timings won't be meaningful.

2. **Rewrite `age/queries/interactive-complex-12.sql`** to the H1 skeleton. Preserve
   the d1–d6 ladder verbatim. Convert each cypher() output column with the correct
   `::text::bigint` or `::text::graphid` cast (see `interactive-complex-10.sql:11–17`
   for exact form). Header comment must say "the Cypher call" — never `cypher(`
   literally (AGENTS.md §13).

3. **Update `age/scripts/ic12-quicktest.sql`** to PREPARE the new two-cypher form. The
   `$1` parameter goes to both cypher() calls. Keep the BasketballPlayer / MusicalArtist
   / Person test triplet. Add an EXPLAIN ANALYZE step that asserts `Hash Semi Join`
   appears and `agtype_in_operator` does NOT appear in any Join Filter.

4. **SF3 correctness validation**: run `bash age/driver/validate.sh
   age/driver/validate-local.properties` against `age/datasets/validation_params-sf3.csv`.
   Target: IC12 failures drop from 132 to ~0. If `tagNames` format differs (Neo4j's
   `collect()` insertion order vs our alphabetised `string_agg`), iterate on the
   `ORDER BY` clause inside `string_agg`. Worst-case fallback: do tagNames inside
   Cypher (`collect(DISTINCT tag.name)`) and pay the AGE aggregation cost for that one
   column only — count(DISTINCT) stays in SQL.

5. **SF3 timing**: 3 runs of `ic12-quicktest.sql`, report 3rd (warm cache). Targets:
   - BasketballPlayer <2s
   - MusicalArtist <5s
   - Person <8s

   Compare EXPLAIN to confirm Hash Semi Join is used.

6. **SF10 timing on production server**: send updated quicktest to operator with SF10
   access, request results. Target: Person <15s.

7. **Append Phase 8 to `age/ic12-optimization-bottlenecks.md`**: document the H1
   design, before/after timings, EXPLAIN comparison, AGENTS.md compliance checklist.
   Mark Phase 7's "Updated sequence" as superseded.

8. **Fallback (S1) if step 5 misses targets**: design `PostTagClass` side table
   mirroring HAS_TAG × Tag.tagclass_id, maintained by IU6. Estimated ~150 GB at SF1000
   — large but doable on the 256 GB tier. Do **not** start S1 design until H1
   measurements come back; H1 is projected to meet target.

---

## Verification

End-to-end test procedure:

```bash
# 1. Pre-flight: confirm query is well-formed
cd /home/emumba/Projects/benchmark/age-ahmed/ldbc_snb_interactive_v1_impls
grep -c "cypher(" age/queries/interactive-complex-12.sql        # must be 2
grep -E 'ldbc_snb\."' age/queries/interactive-complex-12.sql    # must be empty

# 2. SF3 smoke test (3 runs, warm cache)
for i in 1 2 3; do
  PGPASSWORD=mysecretpassword psql -h localhost -p 5433 -U postgres -d ldbcsnb \
    --no-psqlrc -P pager=off -f age/scripts/ic12-quicktest.sql 2>&1 \
    | tee /tmp/ic12-h1-run${i}.log
done
grep -E "Hash Semi Join|agtype_in_operator|^Time:" /tmp/ic12-h1-run3.log

# 3. Correctness against LDBC params
bash age/driver/validate.sh age/driver/validate-local.properties
# Expect: IC12 incorrect count drops from 132 → ~0

# 4. Compare timings to Phase 5 baseline
# Targets (SF3, warm cache, person 15393162799074):
#   BasketballPlayer : was ~7s, target <2s
#   MusicalArtist    : was ~18s, target <5s
#   Person (broad)   : was ~51s, target <8s
```

### EXPLAIN-level checks (must all be true on Person/broad)

- ✅ `Hash Semi Join` node appears with `valid_tag_ids` on the build side.
- ✅ `agtype_in_operator(...)` does **NOT** appear in any Join Filter.
- ✅ The Phase 3 cypher() Function Scan executes once (`loops=1`), not per outer row.
- ✅ `Index Scan using HAS_TAG_start_id_idx` appears in the Cypher plan (Nested Loop
   + Index Scan for HAS_TAG — not Hash Join with Seq Scan, which was the
   inline-HAS_TYPE regression in Phase 7).
- ✅ Final sort row count ≤ 200K (was 482K) for Person/broad.

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| `tagNames` byte-comparison fails LDBC validation due to ordering or escape difference vs Neo4j reference | Validate early (step 4 before tuning). Fallback: keep `collect(DISTINCT tag.name)` inside Cypher Phase 3, return as agtype list — only count(DISTINCT) moves to SQL |
| Planner chooses Hash Join + Seq Scan for HAS_TAG (the inline-HAS_TYPE regression we already saw) | The H1 traversal cypher() has **no** inline HAS_TYPE hop — same shape as today's Phase 3, which uses Nested Loop + Index Scan. EXPLAIN check (step 5) catches a regression |
| Tag names with special characters (quotes, backslashes) break the `'"' \|\| name \|\| '"'` JSON assembly | LDBC dataset tag names are alphanumeric + `_` + `-`. Add defensive `replace()` calls only if validation reveals a counter-example; cost is negligible |
| JDBC handler crashes with "column index out of range" if `cypher(` count drifts from `?` count | Step 1 `grep -c` check before deploying. Both must be 2 |
| SF10 `idx_person_graphid` still missing → measurement noisy | Run `ic12-sf10-index-check.sql` (step 1) before any SF10 timing |
| AGE 1.6's PostgreSQL Function Scan for cypher() doesn't pipeline rows lazily | Won't matter — `MATERIALIZED` already forces a barrier, and `traversal` is consumed once by the EXISTS + GROUP BY. Single pass over the output is what we want |

---

## Out of Scope (explicit non-goals)

- Pre-materialized `FriendTagReplyCount` table — not needed if H1 hits target.
- Patching `agtype_in_operator` upstream in AGE — not a deployable path on Azure
  Horizon DB.
- `SET enable_hashjoin = off` — session-level; affects every other query.
- Inline HAS_TYPE in Cypher — proven to regress narrow tag classes (Phase 7 measured).
- Forcing parallelism — `max_parallel_workers_per_gather` tuning belongs in
  `postgres-tuning.md`, not in the query.
- Migrating IC10's outer-SQL JOINs to `ldbc_snb."Post"`/`."HAS_TAG"` to a compliant
  pattern — separate work item, tracked elsewhere.

---

## Cross-reference: LDBC reference implementations

I reviewed all four LDBC reference implementations of IC12 to validate the H1 design:

| Backend | File | Filter shape | Aggregation |
|---|---|---|---|
| Neo4j (Cypher) | `cypher/queries/interactive-complex-12.cypher` | `tag.id IN tags` (in-Cypher list, with `[:HAS_TYPE\|IS_SUBCLASS_OF*0..]` variable-length walk) | `count(DISTINCT comment)`, `collect(DISTINCT tag.name)` |
| PostgreSQL | `postgres/queries/interactive-complex-12.sql` | `t_tagclassid IN (recursive CTE)` then `mt_tagid = t_tagid` join | `count(*)`, `array_agg(distinct t_name)` |
| DuckDB | `duckdb/queries/interactive-complex-12.sql` | Same as PostgreSQL | `count(*)`, `string_agg(distinct t_name, ';')` |
| Umbra | `umbra/queries/interactive-complex-12.sql` | Same as PostgreSQL | `count(*)`, `string_agg(distinct t_name, ';')` |

### Validation points

1. **All four implementations materialise the valid-tag set BEFORE the main join** — exactly the shape H1 adopts. The SQL backends use a `WITH RECURSIVE` CTE on `tagclass.tc_subclassoftagclassid`; Neo4j uses a variable-length path; we use the d1–d6 ladder (forced by AGE-QUIRKS §4 + §9 which block both variable-length and recursive CTE in Cypher).

2. **`count(DISTINCT comment)` vs `count(*)`**: Neo4j (the **authoritative** reference that generates LDBC validation parameters) uses `count(DISTINCT comment)`. The SQL backends use `count(*)` over the joined `(comment, tag)` row-set, which over-counts when a post has multiple matching tags. This is a quiet divergence — LDBC validation params are byte-comparable to the Neo4j output, so `count(DISTINCT comment)` is the correct semantic. H1 uses `COUNT(DISTINCT t.comment_gid_s)` ✅

3. **tagNames output format**: Neo4j returns a JSON-style list `["a","b"]`. The SQL backends emit either a Postgres `array_agg` representation or a semicolon-separated string. H1's `string_agg(DISTINCT '"' || tag_name_t || '"', ',' ORDER BY ...)` then `::ag_catalog.agtype` matches Neo4j's format (verified empirically with `collect(DISTINCT tag.name)` AGE output in this session — same form).

4. **KNOWS direction**: Neo4j uses undirected `-[:KNOWS]-` (their dataset stores one direction; bidirectional traversal is the spec-correct form). AGE-QUIRKS §11 requires directed `-[:KNOWS]->` because IU8 stores both directions and undirected traversal in AGE disables the seed-node index. H1 uses directed — correct for our schema.

5. **Sort tie-break**: Neo4j uses `toInteger(personId) ASC`. H1 casts `friend.id` to `bigint` early (`(friend_id::text::bigint) AS friend_biz_id`) so the tie-break sort operates on plain bigint — same effect, same ordering.

### What H1 borrows from each

- **Materialised valid-tag CTE** → all four references (universal pattern)
- **`MATERIALIZED` keyword + bigint cast on both sides of the IN check** → mirrors PostgreSQL's planner-friendly subquery form, lets PG use Hash Semi Join
- **JSON-array `tagNames` format** → Neo4j (matches validation params)
- **`count(DISTINCT comment)`** → Neo4j (only correct semantic)
- **d1–d6 ladder** → existing AGE convention, no reference precedent (AGE-specific workaround)
- **Two cypher() calls** → AGE-specific (IU7 pattern); no reference impl needs this because they have native recursion or variable-length paths

### What we explicitly do NOT borrow

- The SQL impls' `count(*)` — incorrect semantic vs the Neo4j-generated validation params
- Neo4j's `[:HAS_TYPE|IS_SUBCLASS_OF*0..]` — crashes in AGE 1.6
- Neo4j's undirected `-[:KNOWS]-` — defeats AGE indexes
- Postgres-style `array_agg` of agtype list — Neo4j format is canonical for byte-compare

---

## Status of Other Approaches Considered (NOT recommended for IC12)

These were evaluated and rejected. Documented here so future readers don't re-explore them.

| Approach | Why rejected |
|---|---|
| **Two-call split with parameter-bound `validTagIds`** (no SQL filter) | `agtype_in_operator` still does linear scan even when the array arrives as a bound Cypher parameter; doesn't fix the bottleneck |
| **Per-post intermediate `collect(DISTINCT tag.name)`** | Reduces sort row count ~2× but does not address the 22s agtype_in_operator scan, which is the dominant cost |
| **Reverse-direction traversal** (TagClass → Tag → HAS_TAG → Post → friend) | Drives from a 5,085-row set for broad classes — worse than current 1,190-friend driver. Improves narrow, regresses broad — wrong trade |
| **HAS_TAG.tagclass_id denorm column** | AGE 1.6 blocks ALTER TABLE on edge label tables (AGE-QUIRKS §9). Only feasible via side table — see S1 fallback |
| **S1: PostTagClass side table** (mirror HAS_TAG × Tag.tagclass_id) | ~150 GB at SF1000, requires IU6 maintenance code, backfill complexity. Kept as fallback only if H1 misses targets |
| **AGE source patch (hash-based agtype_in_operator)** | Out of scope — Azure Horizon DB ships its own AGE build |
