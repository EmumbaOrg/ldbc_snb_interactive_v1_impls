-- LdbcQuery5 — Recent forums (joined after minDate) that 1- or 2-hop friends joined, with post counts.
-- Hybrid: Cypher call fetches 1+2-hop friend graphids via fixed-depth MATCH UNION (no variable-length
-- path per AGE-QUIRKS §4); SQL JOINs HAS_MEMBER + Forum + ForumMemberPostCount side table.
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11 — undirected forces a KNOWS seq scan; IU8 stores
-- both directions so directed traversal finds all friends via idx_knows_start.
-- Denorm used: ForumMemberPostCount(forum_id, member_id) (iter-2 aggregate side table).

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
