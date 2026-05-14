# IC3 + IC4 Correctness + Optimization Plan

## Context

The 2026-05-13 LDBC-official correctness check (partial, ~10.8% of 145K ops at SF3) attributed **71 failures to IC3** and **105 failures to IC4** — placing them in the top-5 offenders alongside IC7, IC12 (just fixed), and IC11/IC1.

Both counts were collected via the off-by-one attribution recipe described in the histogram caveat (see `correctness-check-2026-05-13.md` lines 31-42). IC5's analogous 85 failures resolved to **zero** real failures under focused re-validation, so IC3 and IC4 totals are likely inflated. We still expect *some* real correctness drift in both — the goal is to first quantify it, then fix it correctly, then optimize for SF100-SF1000 in one pass.

IC3 was disabled in `age/driver/validate.properties` (`LdbcQuery3_enable=false`) — re-enabled 2026-05-14 after the fix landed. IC4 was parameterized and live throughout.

The intended outcome: both queries pass focused validation byte-for-byte against the Neo4j reference, with SF100-SF1000 latencies consistent with IC5/IC12 (sub-30s SF100, scalable to SF1000 on the 256 GB Horizon DB tier).

## Phase 0 — Correctness Diagnosis

Rather than per-query scripts, we built a single generic harness: `age/scripts/spot-check.py`. It covers any registered query and uses the same PREPARE/EXECUTE pattern as `ic12-spot-check.py`.

```bash
python3 age/scripts/spot-check.py --query IC3 --sf 3 --limit 50
python3 age/scripts/spot-check.py --query IC4 --sf 3 --limit 100 --nonzero
python3 age/scripts/spot-check.py --query IC3 --sf 3 --all   # ~1-2 hr
python3 age/scripts/spot-check.py --query IC4 --sf 3 --all
```

Run sequence per target query:
1. `--limit 50` smoke (mixed zero/non-zero).
2. `--limit 100 --nonzero` (verifies result content).
3. `--all` on SF3 (~6.8K cases per query, ~1-2 hr).

Record outcomes in `correctness-check-2026-05-13.md`. If both are zero/near-zero after diagnosis, the plan collapses to a pure optimization pass and we re-prioritize against IC7/IC11/IC1.

## Phase 1 — IC3 Rewrite

**Target file**: `interactive-complex-3.sql`.

### Likely failure sources (verify with Phase 0)

1. **Outer SQL `countryName::text = $countryXName`** — agtype string casts to `"Nigeria"` (with JSON double-quotes) while `$countryXName` binds as `Nigeria` (plain SQL text). This systemic cast mismatch would make every xCount and yCount 0, filtering all results via HAVING. **Most likely root cause.**
2. Mixed node/graphid dedup: `d2 <> p` (node comparison) alongside `NOT id(d2) IN direct_ids` (graphid comparison) — AGE-QUIRKS §6/§7 recommends consistent graphid comparisons.
3. Foreign-country anti-join as a required MATCH — fragile if any City is missing IS_PART_OF.

### Three approaches

#### Approach A — Cypher hardening (recommended first, no schema change)

Keep the 2-arm UNION ALL shape. Fix the cast bug by moving country comparison logic inside Cypher (where string comparisons work). Replace the outer CASE sums with Cypher-side CASE or pre-aggregation. Replace mixed node/graphid dedup with UNION-of-1-hop+2-hop deduplication (from IC9 V4 idiom). Flip drive direction from country-side to friend-driven `(friend)<-[:HAS_CREATOR]-(msg)-[:IS_LOCATED_IN]->(country)` using `idx_post_creator_id` / `idx_comment_creator_id`.

- **Correctness**: eliminates the agtype cast mismatch; pure-graphid dedup.
- **Schema cost**: none.
- **Expected perf**: 5-10× at SF100 (drive direction was wrong).
- **AGENTS.md §13/§14**: 2 `cypher(` calls; outer SQL only reads `PersonSide`.
- **Becomes parameterized**: add IC3 to `age_parameterized_queries`.

#### Approach B — IC12-style three-CTE hybrid

Extract the friend set into a `MATERIALIZED` CTE (bigint IDs). Two more `cypher(` CTEs pre-aggregate `(friend_id, x_count, y_count)` per message type in Cypher; outer SQL Hash Joins on bigint. Pre-aggregation shrinks emitted rows by ~10⁴-10⁶ at SF1000.

- **Correctness**: same cast fix as A; pre-aggregation removes the CASE-sum-on-agtype path.
- **Schema cost**: none.
- **Expected perf**: 10-20× at SF100/SF1000.
- **Risk**: split 2-hop OPTIONAL MATCH into single hops per AGE-QUIRKS §12.
- **AGENTS.md §13/§14**: 3 `cypher(` calls; `PersonSide` only.

#### Approach C — `PersonCountry` + extend `MessageByCreator` with `country_name`

Add tiny `PersonCountry(person_business_id, country_name)` side table. Extend `MessageByCreator` with `country_name text` + composite index `(creator_business_id, country_name, creation_date)`. Collapse query to one Cypher call (friend set) + 100% relational outer aggregation.

- **Correctness**: eliminates agtype casts entirely; country names are native SQL text.
- **Schema cost**: `MessageByCreator` grows ~30%; `PersonCountry` ~800 MB at SF1000. IU1/IU6/IU7 each need a country lookup.
- **Expected perf**: 50-200 ms at SF1000.
- **Justified only if** IC2/IC9 share the extended `MessageByCreator` — audit before committing.

### Recommendation

Land **A** first (correctness, zero schema churn). Measure at SF10/SF100. Escalate to **B** if SF100 budget is missed. Hold **C** for SF1000 Horizon targets after cross-query storage audit.

## Phase 2 — IC4 Rewrite

**Target file**: `interactive-complex-4.sql`.

### Likely failure sources (verify with Phase 0)

1. **`tag.name` agtype-quoted string round-trip** — agtype string `"Foo"` returns with JSON double-quotes; outer SQL `ORDER BY tagName ASC` sorts the agtype textual form, which may not match Neo4j reference ordering for tags with special characters. **Most likely root cause.**
2. `WITH DISTINCT tag, post → sum(CASE ...)` CASE-counter — order-fragile for popular tags spanning many friends.
3. KNOWS direction (directed `-[:KNOWS]->` vs Neo4j undirected) — IU8 bidirectional storage means directed finds all friends; confirmed non-issue per AGE-QUIRKS §11.

### Three approaches

#### Approach A — Two-cypher() hybrid with SQL anti-join (recommended first, no schema change)

Mirror of IC12 H1: one `cypher(` CTE materializes `(tag_biz_id bigint, tag_name text, post_biz_id bigint)` for in-window friend posts; a second `cypher(` CTE materializes DISTINCT `tag_biz_id bigint` for the pre-window disqualified tag set. Outer SQL: `NOT EXISTS` hash anti-join on bigint, `COUNT(DISTINCT post_biz_id)` group, `ORDER BY postCount DESC, tag_name ASC LIMIT 10`. `tag_name` is clean SQL text throughout.

- **Correctness**: `tag_name::text` eliminates agtype quoting from sort path; explicit set-difference matches spec semantics exactly.
- **Schema cost**: none.
- **Expected perf**: 3-5× SF100, 5-10× SF1000.
- **AGENTS.md §13/§14**: 2 `cypher(` calls; outer SQL reads only CTE results. Comments must not contain `cypher(`.

```sql
WITH in_window AS MATERIALIZED (
  SELECT (tag_id::text::bigint) AS tag_biz_id,
         tag_name::text          AS tag_name_t,
         (post_id::text::bigint) AS post_biz_id
  FROM cypher('ldbc_snb', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WITH friend
    MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
    WHERE post.creationDate >= $startDate AND post.creationDate < $endDate
    WITH post
    MATCH (post)-[:HAS_TAG]->(tag:Tag)
    RETURN post.id, tag.id, tag.name
  $$, $1) AS x(post_id agtype, tag_id agtype, tag_name agtype)
),
pre_window AS MATERIALIZED (
  SELECT DISTINCT (tag_id::text::bigint) AS tag_biz_id
  FROM cypher('ldbc_snb', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WITH friend
    MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
    WHERE post.creationDate < $startDate
    WITH post
    MATCH (post)-[:HAS_TAG]->(tag:Tag)
    RETURN tag.id
  $$, $1) AS x(tag_id agtype)
),
agg AS (
  SELECT iw.tag_name_t,
         COUNT(DISTINCT iw.post_biz_id) AS post_count
  FROM in_window iw
  WHERE NOT EXISTS (SELECT 1 FROM pre_window pw WHERE pw.tag_biz_id = iw.tag_biz_id)
  GROUP BY iw.tag_name_t
  ORDER BY post_count DESC, iw.tag_name_t ASC
  LIMIT 10
)
SELECT ('"' || tag_name_t || '"')::ag_catalog.agtype AS tagName,
       post_count::ag_catalog.agtype                  AS postCount
FROM agg
ORDER BY post_count DESC, tag_name_t ASC;
```

#### Approach B — Single-cypher() set-difference via `WHERE NOT IN collect()`

Keep one `cypher(` call. First MATCH collects `collect(DISTINCT preTag.id)` from all pre-window posts; second MATCH applies `WHERE NOT (tag.id IN preTagIds)` before aggregating. Eliminates the `WITH DISTINCT tag, post → CASE/sum` indirection.

- **Correctness**: explicit set-difference; tag.name still cast to text in outer SELECT.
- **Schema cost**: none.
- **Expected perf**: ~2× SF100, ~1.5× SF1000 (still pays Cypher executor GROUP BY).
- **Risk**: large `friendGids` IN list (~5K) — verify EXPLAIN at SF10 for seq-scan vs index probe.
- **AGENTS.md §13/§14**: 1 `cypher(` call.

#### Approach C — `PostTagByCreator` side table + one-cypher hybrid probe

New `PostTagByCreator(creator_id graphid, post_biz_id bigint, tag_biz_id bigint, tag_name text, creation_date bigint)` with composites `(creator_id, creation_date)` and `(creator_id, tag_biz_id, creation_date)`. Cypher returns friend graphids; outer SQL drives in-window aggregation and `NOT EXISTS` anti-join entirely on the side table.

- **Correctness**: no agtype comparisons in the hot path.
- **Schema cost**: ~140 GB at SF1000 (rows + indexes). Hours-long backfill. Justified only if IC6/IC10 share the table.
- **Expected perf**: 8-15× SF100, 15-30× SF1000.
- **AGENTS.md §13/§14**: 1 `cypher(` call; outer SQL reads side table only.

### Recommendation

Land **A** first (correctness, zero schema). Measure at SF10/SF100. **B** is a fallback if JDBC two-`?` binding hits a snag. **C** only after IC6/IC10 audit justifies the 140 GB investment.

## AGENTS.md Compliance Checklist

- **§13**: No `cypher(` literal in SQL comments for parameterized queries. `grep -c "cypher("` must equal `?`-count.
- **§14**: Outer SQL reads only side tables or CTE results. Never `ldbc_snb."Post"`, `ldbc_snb."HAS_TAG"`, etc.
- **AGE-QUIRKS §11**: KNOWS always directed `-[:KNOWS]->`.
- **AGE-QUIRKS §9**: No variable-length paths — explicit 1-hop + 2-hop ladders.
- **AGE-QUIRKS §5**: No `ORDER BY` on RETURN aliases inside Cypher.
- **AGE-QUIRKS §12**: Split 2-hop OPTIONAL MATCH into single hops with intermediate `WITH`.

## Verification

```bash
# 1. Compliance pre-flight (run after every rewrite)
grep -c "cypher(" age/queries/interactive-complex-3.sql   # IC3 actual: 3 (friends + Comment arm + Post arm)
grep -c "cypher(" age/queries/interactive-complex-4.sql   # IC4 Approach A: 2
grep -E 'ldbc_snb\."(Post|Comment|HAS_TAG|HAS_CREATOR|IS_LOCATED_IN|KNOWS)"' \
     age/queries/interactive-complex-3.sql                # must be empty ✅
grep -E 'ldbc_snb\."(Post|Comment|HAS_TAG|HAS_CREATOR|IS_LOCATED_IN|KNOWS)"' \
     age/queries/interactive-complex-4.sql                # must be empty ✅

# 2. Spot-check (via generic harness)
# IC3: 50/50 ✅ + 100/100 nonzero ✅ + 6,818/6,818 full corpus ✅ (2026-05-14)
# IC4: 50/50 ✅ + 6,818/6,818 full corpus ✅ (2026-05-14)
python3 age/scripts/spot-check.py --query IC3 --sf 3 --limit 50
python3 age/scripts/spot-check.py --query IC4 --sf 3 --limit 50
python3 age/scripts/spot-check.py --query IC3 --sf 3 --limit 100 --nonzero
python3 age/scripts/spot-check.py --query IC4 --sf 3 --limit 100 --nonzero
python3 age/scripts/spot-check.py --query IC3 --sf 3 --all
python3 age/scripts/spot-check.py --query IC4 --sf 3 --all

# 3. Re-enable IC3/IC4 in driver properties (done 2026-05-14):
#    age/driver/validate.properties: LdbcQuery3_enable=true, LdbcQuery4_enable=true
#    IC3 added to age_parameterized_queries in benchmark.properties + validate.properties
bash age/driver/validate.sh age/driver/validate.properties

# 4. SF3 EXPLAIN ANALYZE (2026-05-14): ✅
#    IC3: idx_knows_start both UNION arms, IS_LOCATED_IN_end_id_idx for country scan,
#         country filter inside Cypher (agtype vs agtype), Hash Join on graphid. ~290ms SF3.
#    IC4 Approach A: NOT EXISTS Hash Anti Join on tag_biz_id; no agtype_in_operator in Join.
```

## Related files

| File | Role |
|---|---|
| `age/scripts/spot-check.py` | Generic validation harness (IC3, IC4, IC12 registered) |
| `age/scripts/ic12-spot-check.py` | Original IC12 harness (kept for back-compat; `spot-check.py` supersedes it) |
| `age/queries/correctness-check-2026-05-13.md` | Attribution caveat + per-query status table |
| `age/queries/interactive-complex-5.sql` | Gold-standard hybrid reference (MATERIALIZED CTE + side-table join) |
| `age/queries/interactive-complex-12.sql` | H1 two-CTE hybrid reference (IC4 Approach A shape) |
| `age/driver/validate.properties` | ✅ `LdbcQuery3_enable=true`, `LdbcQuery4_enable=true` (re-enabled 2026-05-14); `Query3` added to `age_parameterized_queries` |
| `age/driver/benchmark.properties` | ✅ IC3 added to `age_parameterized_queries` (2026-05-14); comment updated to note 3 Cypher calls bound to `$1` |
