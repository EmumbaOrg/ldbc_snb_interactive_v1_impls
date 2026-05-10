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

### DB Tuning Applied
```sql
ALTER DATABASE ldbcsnb SET max_parallel_workers_per_gather = 2;
ALTER DATABASE ldbcsnb SET work_mem = '8MB';
```
