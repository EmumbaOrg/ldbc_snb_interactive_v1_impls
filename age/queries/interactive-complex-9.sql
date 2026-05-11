-- LdbcQuery9 — Recent messages by friends and friends-of-friends (V4 — hybrid: Cypher reach + SQL walk)
--
-- V3 was pure SQL. The 2-hop friend reach is now in Cypher (one cypher() call
-- using fixed-depth MATCH UNION — no variable-length path per AGE-QUIRKS §4).
-- SQL retains the date-DESC index walk on idx_comment_date_id / idx_post_date_id
-- with a Nested Loop Semi Join against the friend set — the planner stops the
-- index walk as soon as 20 friend-authored rows accumulate. This is the
-- SF1000-critical optimisation; it is not a cosmetic detour.
--
-- Why Cypher UNION is semantically equivalent to V3 SQL's (direct UNION foaf):
--   V3 computed: all_friends = 1-hop UNION (2-hop MINUS 1-hop MINUS self).
--   V4 Cypher computes: UNION of {1-hop MINUS self} and {2-hop MINUS self}.
--   UNION deduplication ensures each graphid appears once. The result set is
--   identical: every person within 2 hops of the seed person, excluding self.
--   Verified byte-for-byte against V3 on 2 SF3 sample inputs.
--
-- AGE 1.6 note: `NOT (p)-[:KNOWS]-(f2)` with relationship type in pattern
-- negation is rejected by the parser ("syntax error at or near ':'"). The
-- UNION deduplication approach is used instead — semantically equivalent.
--
-- DIRECTED TRAVERSAL REQUIRED (AGE-QUIRKS §11): This query uses `-[:KNOWS]->`
-- (directed) rather than `-[:KNOWS]-` (undirected). Undirected KNOWS traversal
-- forces a sequential scan of the entire KNOWS edge table (1.13 M rows at SF3,
-- ~80 M rows at SF1000), causing the all_friends CTE to take ~4.9 s at SF3 —
-- a 25x budget overrun. Directed `->` traversal uses idx_knows_start and runs
-- in ~50–100 ms. This is semantically correct because IU8 stores KNOWS edges
-- bidirectionally: every friendship (p1, p2) creates both p1->p2 AND p2->p1
-- edges. So MATCH (p)-[:KNOWS]->(f) finds ALL of p's friends via outgoing edges.
-- This is the same pattern used by IC10 V5 (see interactive-complex-10.sql line 30).
--
-- Parameterization: stays OUT of age_parameterized_queries — the cypher()
-- call uses $personId (Cypher param) while the outer SQL uses $maxDate
-- (string-interpolated). The two can't share a single agtype JSON bind.
--
-- SF3 budget: < 200 ms mean. SF1000 budget: < 800 ms mean.

WITH all_friends AS (
  SELECT (g::text)::ag_catalog.graphid AS friend_id
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(f1:Person)
    WHERE f1.id <> $personId
    RETURN id(f1) AS friend_gid
    UNION
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(f2:Person)
    WHERE f2.id <> $personId
    RETURN id(f2) AS friend_gid
  $$) AS x(g agtype)
),
top_comments AS (
  -- Walk idx_comment_date_id from `< $maxDate` backwards; planner stops
  -- the index walk as soon as the Nested Loop Semi Join accumulates 20 rows
  -- whose creator is in all_friends.
  SELECT msg.id        AS msg_gid,
         msg.properties AS msg_props,
         hc.end_id     AS author_gid,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) AS cdate,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint)           AS msg_id_biz
  FROM ldbc_snb."Comment" msg
  JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = msg.id
  WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) < $maxDate
    AND hc.end_id IN (SELECT friend_id FROM all_friends)
  ORDER BY 4 DESC, 5 ASC
  LIMIT 20
),
top_posts AS (
  SELECT msg.id        AS msg_gid,
         msg.properties AS msg_props,
         hc.end_id     AS author_gid,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) AS cdate,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint)           AS msg_id_biz
  FROM ldbc_snb."Post" msg
  JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = msg.id
  WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) < $maxDate
    AND hc.end_id IN (SELECT friend_id FROM all_friends)
  ORDER BY 4 DESC, 5 ASC
  LIMIT 20
)
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"id"'::ag_catalog.agtype])         AS personId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"firstName"'::ag_catalog.agtype])  AS personFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"lastName"'::ag_catalog.agtype])   AS personLastName,
  t.msg_id_biz::ag_catalog.agtype                                                                      AS messageId,
  COALESCE(
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.msg_props, '"content"'::ag_catalog.agtype]),
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.msg_props, '"imageFile"'::ag_catalog.agtype])
  )                                                                                                    AS messageContent,
  t.cdate::ag_catalog.agtype                                                                           AS messageCreationDate
FROM (SELECT * FROM top_comments UNION ALL SELECT * FROM top_posts) t
JOIN ldbc_snb."Person" per ON per.id = t.author_gid
ORDER BY t.cdate DESC, t.msg_id_biz ASC
LIMIT 20;

-- ----------------------------------------------------------------------------
-- Future optimization steps (pick up when needed):
--
-- 1. Schema denormalization for SF1000 — at higher SFs, friend density of the
--    date window can drop, lengthening the date-DESC index walk before 20
--    friend-authored rows are found. The fix is to push creationDate into the
--    HAS_CREATOR edge itself (populated by IU6/IU7 and backfilled at load),
--    then add a composite index:
--      ALTER TABLE ldbc_snb."HAS_CREATOR" ADD COLUMN creation_date bigint;
--      CREATE INDEX idx_hascreator_end_creationdate
--        ON ldbc_snb."HAS_CREATOR" (end_id, creation_date DESC);
--    With that, IC9 becomes a k-way merge of per-friend top-20 streams —
--    O(log N + 20) per friend, robust regardless of friend density. Touches
--    IU operations, schema, and load — out of scope for the query rewrite.
--
-- 2. Apply the same V3 pattern to IC2 — sibling query (recent messages by
--    direct friends only, no FoF). Same 2-branch UNION ALL shape; replacing
--    with a date-driven semi-join CTE should drop IC2 from ~115 ms mean to
--    single-digit ms. Quick follow-up if it shows up in profiling again.
--
-- 3. Investigate AGE's per-call cypher() overhead — the SQ6, IS4, and IC9
--    rewrites have all sidestepped a fixed ~150 ms tax that appears whenever
--    cypher() returns string content. Worth a profiling session to identify
--    where in AGE's parse → execute → serialize path that overhead lives,
--    so it can be fixed for queries that genuinely need Cypher.
-- ----------------------------------------------------------------------------
