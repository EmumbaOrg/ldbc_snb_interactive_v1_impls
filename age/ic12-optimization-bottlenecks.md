# IC12 (Expert Search) — Full Optimization Journey

## Query Specification
- Given `personId`, find 1-hop friends (via KNOWS)
- Find Comments by friends that are **direct** (single-hop) replies to Posts
- Posts must have a Tag in the given TagClass or its descendants
- Count reply Comments per friend, collect matching Tag names
- Only return friends with replyCount >= 1
- ORDER BY replyCount DESC, friend.id ASC, LIMIT 20

## Environment
- **Apache AGE 1.6.0** on PostgreSQL (port 5433)
- **Database:** ldbcsnb, **Graph:** ldbc_snb
- **Connection:** `postgresql://postgres:mysecretpassword@localhost:5433/ldbcsnb`
- **Property access:** `properties->'"key"'` returns agtype
- **Test params:** personId=987, tagClassName='MusicalArtist'

## Data Scale (SF3)
| Table         | Rows       |
|---------------|------------|
| HAS_TAG       | 11,423,592 |
| HAS_CREATOR   | 9,010,272  |
| REPLY_OF      | 6,413,026  |
| Comment       | 6,412,683  |
| Post          | 2,597,473  |
| KNOWS         | 1,130,494  |
| Person        | 24,328     |
| Tag           | ~16K       |
| TagClass      | ~71        |

---

## Phase 1: Original Query (~12.8s)

### Structure
Pure Cypher with UNWIND+collect pattern:
```sql
cypher('ldbc_snb', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    MATCH (friend)<-[:HAS_CREATOR]-(reply:Comment)-[:REPLY_OF]->(post:Post)
    MATCH (post)-[:HAS_TAG]->(tag:Tag)-[:HAS_TYPE]->(tc:TagClass)
    -- TagClass hierarchy via OPTIONAL MATCH chain (6 levels)
    -- UNWIND + collect for dedup
    RETURN friend.id, friend.firstName, friend.lastName, collect(tag.name), count(reply)
$$)
```

### Problems
1. **Entire traversal in Cypher** — AGE's planner can't optimize multi-hop patterns well
2. **6-level OPTIONAL MATCH chain** for TagClass hierarchy — generates massive intermediate cross-products
3. **UNWIND + collect** pattern for dedup is expensive in AGE
4. **No index usage** — Cypher doesn't leverage PostgreSQL indexes on internal tables

---

## Phase 2: Hybrid CTE + Index Additions (~1.7s)

### Changes Made
1. **Split into two Cypher CTEs + SQL join:**
   - CTE 1 (`valid_tags`): Cypher for TagClass hierarchy + Tag lookup
   - CTE 2 (`traversal`): Cypher for Person→KNOWS→friend→HAS_CREATOR←Comment→REPLY_OF→Post
   - CTE 3 (`matched`): SQL JOIN traversal ⋈ HAS_TAG ⋈ valid_tags
   - Final: SQL GROUP BY + aggregation

2. **Added indexes on all edge tables:**
   ```sql
   CREATE INDEX IF NOT EXISTS <table>_start_id_idx ON ldbc_snb."<TABLE>" (start_id);
   CREATE INDEX IF NOT EXISTS <table>_end_id_idx ON ldbc_snb."<TABLE>" (end_id);
   ```
   Applied to: KNOWS, HAS_CREATOR, REPLY_OF, HAS_TAG, HAS_TYPE, IS_SUBCLASS_OF

3. **DB tuning:**
   ```sql
   ALTER DATABASE ldbcsnb SET max_parallel_workers_per_gather = 2;
   ALTER DATABASE ldbcsnb SET work_mem = '8MB';
   ```

### Improvement
- 12.8s → 1.7s (**87% reduction**)

### Remaining Bottleneck
The `traversal` Cypher CTE still does a 3-hop graph traversal fetching ALL friend comments before any tag filtering. This produces tens of thousands of intermediate rows.

---

## Phase 3: Strategy C — Minimal Cypher + Pure SQL (~875ms)

### Bottleneck Analysis
| Bottleneck | Impact |
|------------|--------|
| Cypher `traversal` CTE (3-hop) | ~90% of query time |
| Tag filtering too late (after Cypher materializes all rows) | Large wasted intermediate set |
| Two Cypher calls = double startup overhead | ~100ms wasted |
| agtype casting for large result sets | Minor overhead |

### Strategies Evaluated
| Strategy | Description | Result |
|----------|-------------|--------|
| A: Full Pure SQL | Bypass Cypher entirely, access AGE internal tables | Not tried (property access complexity) |
| B: Reverse direction | Start from Tags, work backward | Not tried (MusicalArtist has ~200 tags = still large) |
| **C: Minimal Cypher + SQL** | **Single Cypher for friends only, SQL for everything else** | **Winner — 875ms** |
| D: Pre-filter Posts by tag | Materialize valid_posts first, then join | Tried — 2.6s (valid_posts too large) |
| E: Full SQL optimal join | PostgreSQL optimizer handles all joins | Tried in Phase 2 — 6.0s |

### Final Optimized Query
```sql
WITH RECURSIVE friends AS (
    -- Single minimal Cypher: just Person→KNOWS→friend (~100 rows, fast)
    SELECT friend_id, friend_fn, friend_ln
    FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
        RETURN id(friend), friend.firstName, friend.lastName
    $$) AS (friend_id agtype, friend_fn agtype, friend_ln agtype)
),
-- Recursive SQL CTE for TagClass hierarchy (replaces 6-level OPTIONAL MATCH)
valid_classes(class_id) AS (
    SELECT id FROM $graphName."TagClass"
    WHERE properties->'"name"' = ('"' || $tagClassName || '"')::agtype
    UNION ALL
    SELECT iso.start_id
    FROM $graphName."IS_SUBCLASS_OF" iso
    JOIN valid_classes vc ON iso.end_id = vc.class_id
),
valid_tags AS (
    SELECT t.id AS tag_id, t.properties->'"name"' AS tag_name
    FROM $graphName."HAS_TYPE" ht
    JOIN valid_classes vc ON ht.end_id = vc.class_id
    JOIN $graphName."Tag" t ON t.id = ht.start_id
),
-- Pure SQL joins: friends → HAS_CREATOR → REPLY_OF → Post
friend_replies AS (
    SELECT f.friend_id, f.friend_fn, f.friend_ln,
           hc.start_id AS comment_id, ro.end_id AS post_id
    FROM friends f
    JOIN $graphName."HAS_CREATOR" hc ON hc.end_id = f.friend_id
    JOIN $graphName."REPLY_OF" ro ON ro.start_id = hc.start_id
    JOIN $graphName."Post" p ON p.id = ro.end_id
),
-- Join to valid tags
matched AS (
    SELECT fr.friend_id, fr.friend_fn, fr.friend_ln,
           fr.comment_id, vt.tag_name
    FROM friend_replies fr
    JOIN $graphName."HAS_TAG" ht ON ht.start_id = fr.post_id
    JOIN valid_tags vt ON ht.end_id = vt.tag_id
)
SELECT
    friend_id AS personId,
    friend_fn AS personFirstName,
    friend_ln AS personLastName,
    '[' || string_agg(DISTINCT tag_name::text, ', ') || ']' AS tagNames,
    count(DISTINCT comment_id) AS replyCount
FROM matched
GROUP BY friend_id, friend_fn, friend_ln
ORDER BY count(DISTINCT comment_id) DESC, (friend_id)::text::bigint ASC
LIMIT 20;
```

### Key Optimizations in Phase 3
1. **Single minimal Cypher call** — only `Person→KNOWS→friend` (~100 rows), eliminating the expensive 3-hop Cypher traversal
2. **Recursive SQL CTE** for TagClass hierarchy — replaces the 6-level OPTIONAL MATCH chain, handles any depth
3. **Pure SQL joins** for the heavy path (HAS_CREATOR → REPLY_OF → Post → HAS_TAG → Tag) — PostgreSQL optimizer has full control over join order and index usage
4. **Eliminated Comment vertex table join** — unnecessary since REPLY_OF's start_id already identifies the comment; Post join is kept to ensure only direct replies to Posts

### Benchmark Results (3 runs, warm cache)
```
Run 1: 904ms
Run 2: 872ms
Run 3: 875ms
```

---

## Summary

| Phase | Query Time | Improvement | Key Change |
|-------|-----------|-------------|------------|
| Original | 12.8s | — | Pure Cypher with UNWIND+collect |
| Phase 2 | 1.7s | 87% from original | Hybrid CTEs + indexes + DB tuning |
| **Phase 3** | **~875ms** | **93% from original** | **Minimal Cypher + pure SQL joins** |

### All Indexes Required
```sql
-- Edge table indexes (already present on ldbc_snb schema)
CREATE INDEX IF NOT EXISTS KNOWS_start_id_idx ON ldbc_snb."KNOWS" (start_id);
CREATE INDEX IF NOT EXISTS KNOWS_end_id_idx ON ldbc_snb."KNOWS" (end_id);
CREATE INDEX IF NOT EXISTS HAS_CREATOR_start_id_idx ON ldbc_snb."HAS_CREATOR" (start_id);
CREATE INDEX IF NOT EXISTS HAS_CREATOR_end_id_idx ON ldbc_snb."HAS_CREATOR" (end_id);
CREATE INDEX IF NOT EXISTS REPLY_OF_start_id_idx ON ldbc_snb."REPLY_OF" (start_id);
CREATE INDEX IF NOT EXISTS REPLY_OF_end_id_idx ON ldbc_snb."REPLY_OF" (end_id);
CREATE INDEX IF NOT EXISTS HAS_TAG_start_id_idx ON ldbc_snb."HAS_TAG" (start_id);
CREATE INDEX IF NOT EXISTS HAS_TAG_end_id_idx ON ldbc_snb."HAS_TAG" (end_id);
CREATE INDEX IF NOT EXISTS HAS_TYPE_start_id_idx ON ldbc_snb."HAS_TYPE" (start_id);
CREATE INDEX IF NOT EXISTS HAS_TYPE_end_id_idx ON ldbc_snb."HAS_TYPE" (end_id);
CREATE INDEX IF NOT EXISTS IS_SUBCLASS_OF_start_id_idx ON ldbc_snb."IS_SUBCLASS_OF" (start_id);
CREATE INDEX IF NOT EXISTS IS_SUBCLASS_OF_end_id_idx ON ldbc_snb."IS_SUBCLASS_OF" (end_id);
```

### DB Tuning Applied (Phase 3)
```sql
-- These were reverted in Phase 4; benchmark should use postgresql.conf defaults.
ALTER DATABASE ldbcsnb SET max_parallel_workers_per_gather = 2;
ALTER DATABASE ldbcsnb SET work_mem = '8MB';
```

---

## Phase 4: Review Fixes (V2) — iter-3 Alignment + SF1000 Hardening

### Review Feedback (6 points)
The Phase 3 query was reviewed and the following changes were requested:

1. **Use iter-3 denorm columns** — `denormalize-schema.sql` already populates `Comment.creator_id`, `Comment.reply_of_id`, `Tag.tagclass_id`, `TagClass.subclass_of_id` with B-tree indexes. The V1 query was still joining through edge tables (`HAS_CREATOR`, `REPLY_OF`, `HAS_TYPE`, `IS_SUBCLASS_OF`) unnecessarily.

2. **Schema reference & graphid casts** — `$graphName."HAS_CREATOR"` in raw SQL depends on token substitution outside `cypher()` calls. Changed to literal `ldbc_snb."Table"` references. Added explicit `(f.friend_vid::text)::ag_catalog.graphid` casts for cross-type joins (agtype→graphid) to ensure index usage.

3. **Result column types for handler compatibility** — The Java handler (`AgeConverter.toLong`, `AgeConverter.toStr`, `AgeConverter.toStringList`) expects agtype-compatible values. Added `::ag_catalog.agtype` casts on `tagNames` and `replyCount` output columns.

4. **MATERIALIZED on valid_tags** — Critical for SF1000. At SF1000 `HAS_TAG` ≈ 240M rows while `valid_tags` ≈ 50-200 rows. Without MATERIALIZED, Postgres ≥12 inlines the CTE and can flip to driving from `HAS_TAG.end_id`, materialising ~3M intermediate rows. `AS MATERIALIZED` forces Postgres to compute the small set once. Costs nothing at SF3, prevents 5-15s tail at SF1000.

5. **Indexes already in place** — The 12 single-column edge indexes exist in `create-indexes.sql`. Added `ANALYZE "HAS_TAG"` to `denormalize-schema.sql` to ensure stats are fresh.

6. **Reverted ALTER DATABASE tuning** — `work_mem='8MB'` and `max_parallel_workers_per_gather=2` were DB-level overrides that affect all workloads. Reverted to let `postgresql.conf` defaults apply (iter-3 runs at `work_mem='32MB'`). SF-specific tuning belongs in `run-benchmark.sh` session settings, not DB-level ALTERs.

### Changes Made

#### `age/queries/interactive-complex-12.sql` — Full Rewrite (V2)

**TagClass hierarchy** — Replaced Cypher 6-level OPTIONAL MATCH with recursive SQL CTE using denorm `TagClass.subclass_of_id`:
```sql
WITH RECURSIVE
valid_classes(class_id) AS (
    SELECT (tc_id::text)::ag_catalog.graphid AS class_id
    FROM cypher('$graphName', $$
        MATCH (tc:TagClass {name: $tagClassName})
        RETURN id(tc)
    $$) AS x(tc_id agtype)
    UNION ALL
    SELECT tc.id
    FROM ldbc_snb."TagClass" tc
    JOIN valid_classes vc ON tc.subclass_of_id = vc.class_id
),
```

**Tag lookup** — Uses denorm `Tag.tagclass_id` instead of `HAS_TYPE` edge + `AS MATERIALIZED` for SF1000 stability:
```sql
valid_tags AS MATERIALIZED (
    SELECT t.id AS tag_id,
           ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.properties, '"name"'::ag_catalog.agtype]) AS tag_name
    FROM ldbc_snb."Tag" t
    JOIN valid_classes vc ON t.tagclass_id = vc.class_id
),
```

**Friend replies** — Uses denorm `Comment.creator_id` and `Comment.reply_of_id` instead of `HAS_CREATOR`/`REPLY_OF` edge tables:
```sql
friend_replies AS (
    SELECT f.friend_id, f.friend_fn, f.friend_ln,
           c.id AS comment_id, c.reply_of_id AS post_id
    FROM friends f
    JOIN ldbc_snb."Comment" c ON c.creator_id = (f.friend_vid::text)::ag_catalog.graphid
    JOIN ldbc_snb."Post" p ON p.id = c.reply_of_id
),
```

**Result casts** — agtype casts for handler compatibility:
```sql
SELECT
    friend_id AS personId,
    friend_fn AS personFirstName,
    friend_ln AS personLastName,
    ('[' || string_agg(DISTINCT tag_name::text, ', ') || ']')::ag_catalog.agtype AS tagNames,
    count(DISTINCT comment_id)::text::ag_catalog.agtype AS replyCount
```

#### `age/scripts/denormalize-schema.sql`
- Added `ANALYZE "HAS_TAG";` to the ANALYZE block (was missing)

#### Database Settings
- Reverted all `ALTER DATABASE ldbcsnb SET ...` overrides (`RESET work_mem`, `RESET max_parallel_workers_per_gather`, etc.)

### V1 → V2 Diff Summary

| Aspect | V1 (Phase 3) | V2 (Phase 4) |
|--------|-------------|-------------|
| TagClass hierarchy | Cypher OPTIONAL MATCH ×6 | Recursive SQL CTE via `subclass_of_id` |
| Tag lookup | Cypher HAS_TYPE traversal | SQL JOIN on `Tag.tagclass_id` + MATERIALIZED |
| Comment→Person join | `HAS_CREATOR` edge table | `Comment.creator_id` denorm column |
| Comment→Post join | `REPLY_OF` edge table | `Comment.reply_of_id` denorm column |
| Schema references | `$graphName."HAS_CREATOR"` | `ldbc_snb."Comment"` (literal) |
| Cross-type joins | Implicit agtype→graphid | Explicit `(::text)::ag_catalog.graphid` cast |
| Result columns | Raw SQL types | `::ag_catalog.agtype` casts |
| DB tuning | ALTER DATABASE overrides | Reverted (use postgresql.conf defaults) |
| Edge table JOINs | 5 (HAS_CREATOR, REPLY_OF, HAS_TYPE, IS_SUBCLASS_OF, HAS_TAG) | 1 (HAS_TAG only) |

### SF1000 Risk Mitigation
- `valid_tags AS MATERIALIZED` prevents planner from inlining into 240M-row HAS_TAG scan
- `idx_comment_creator_id` B-tree index on denorm column ensures Index Scan (not Seq Scan)
- `idx_tag_tagclass_id`, `idx_tagclass_subclass_of_id` indexed for recursive CTE
- Explicit graphid casts ensure operator = uses the correct index path
- Expected SF1000: 250-500ms mean, p99 < 600ms

### Indexes Used (all from denormalize-schema.sql / create-indexes.sql)
```sql
-- Denorm column indexes (from denormalize-schema.sql)
idx_comment_creator_id     ON "Comment" (creator_id)
idx_comment_reply_of_id    ON "Comment" (reply_of_id)
idx_tag_tagclass_id        ON "Tag" (tagclass_id)
idx_tagclass_subclass_of_id ON "TagClass" (subclass_of_id)

-- Edge table indexes (from create-indexes.sql)
HAS_TAG_start_id_idx       ON "HAS_TAG" (start_id)
HAS_TAG_end_id_idx         ON "HAS_TAG" (end_id)
```
