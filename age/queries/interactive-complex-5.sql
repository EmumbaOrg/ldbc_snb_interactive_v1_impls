-- LdbcQuery5 — Recent groups (V11 — Cypher friend tree + SQL aggregate)
--
-- V10 was fake-hybrid: only a trivial Cypher seed for graphid lookup; reach +
-- HAS_MEMBER + Forum + FMPC all done in SQL. V11 restores Cypher as graph
-- navigator for the friend tree (the part that IS graph traversal); HAS_MEMBER
-- + Forum + FMPC stay in SQL because the aggregate side table is what makes
-- the GROUP BY tractable. This mirrors IC10 V5 — the canonical genuine-hybrid
-- shape in this codebase.
--
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11 (undirected forces KNOWS seq scan).
-- KNOWS is stored bidirectionally (IU8 inserts both p1->p2 and p2->p1), so
-- directed walk still finds every friendship via the start_id index.
-- Prior passes used undirected `-[:KNOWS]-` which caused the all_friends CTE
-- to take ~4.6 s at SF3 (seq scan on 1.13 M rows). Directed traversal fixes
-- this — same pattern proven in IC10 V5 (interactive-complex-10.sql line 30).
--
-- Measured at SF3 (sample 1, personId=26388279078570, minDate=…):
--   V10 single-call: 0.83 s wall
--   V11 single-call: target < 2 s mean (< 8 s mean at SF1000)
--
-- SF3 budget: < 2 s mean. SF1000 budget: < 8 s mean.

WITH friends AS (
  SELECT (friend_gid::text)::ag_catalog.graphid AS friend_id
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
    WITH friend, direct WHERE direct IS NULL
    WITH DISTINCT friend
    RETURN id(friend) AS friend_gid
    UNION
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    RETURN id(friend) AS friend_gid
  $$) AS x(friend_gid agtype)
)
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties, '"title"'::ag_catalog.agtype]) AS forumTitle,
  COALESCE(SUM(fmpc.post_count), 0)::int AS postCount
FROM friends fr
JOIN ldbc_snb."HAS_MEMBER" hm ON hm.end_id = fr.friend_id
  AND ag_catalog.agtype_access_operator(VARIADIC ARRAY[hm.properties, '"joinDate"'::ag_catalog.agtype]) > $minDate::ag_catalog.agtype
JOIN ldbc_snb."Forum" f ON f.id = hm.start_id
LEFT JOIN ldbc_snb."ForumMemberPostCount" fmpc
       ON fmpc.forum_id = hm.start_id AND fmpc.member_id = fr.friend_id
GROUP BY hm.start_id, f.properties
ORDER BY postCount DESC,
         (CAST(ag_catalog.agtype_object_field_text(f.properties, 'id') AS bigint)) ASC
LIMIT 20;
