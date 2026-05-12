-- LdbcQuery5 — Recent forums (joined after minDate) that 1- or 2-hop friends joined, with post counts.
-- Hybrid: the Cypher call fetches 1+2-hop friend graphids via fixed-depth MATCH UNION (no variable-length
-- path per AGE-QUIRKS §4); SQL JOINs HAS_MEMBER + Forum + ForumMemberPostCount side table.
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11 — undirected forces a KNOWS seq scan; IU8 stores
-- both directions so directed traversal finds all friends via idx_knows_start.
-- Denorm used: ForumMemberPostCount(forum_id, member_id) (iter-2 aggregate side table).
-- Aggregation pre-groups by hm.start_id (graphid) in the agg CTE; Forum is joined after
-- aggregation so the GROUP BY hashes only on the graphid scalar, not the full properties JSON blob.
-- Phase 2 (Tactic B): replaced the OPTIONAL MATCH antijoin dedup with plain 1-hop UNION 2-hop.
-- UNION set semantics deduplicate naturally (same as postgres/duckdb/Neo4j reference impls).
-- Phase 2 (Tactic C): MATERIALIZED forces the planner to evaluate the friend set before joining
-- HAS_MEMBER, preventing the AGE 1.6 threshold-flip at SF100+ (sf3-final-report §5.1).

WITH friends AS MATERIALIZED (
  SELECT (friend_gid::text)::ag_catalog.graphid AS friend_id
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    RETURN id(friend) AS friend_gid
    UNION
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    RETURN id(friend) AS friend_gid
  $$) AS x(friend_gid agtype)
),
agg AS (
  SELECT hm.start_id AS forum_id,
         COALESCE(SUM(fmpc.post_count), 0)::int AS postCount
  FROM friends fr
  JOIN ldbc_snb."HAS_MEMBER" hm
    ON hm.end_id = fr.friend_id
   AND ag_catalog.agtype_access_operator(VARIADIC ARRAY[hm.properties, '"joinDate"'::ag_catalog.agtype]) > $minDate::ag_catalog.agtype
  LEFT JOIN ldbc_snb."ForumMemberPostCount" fmpc
    ON fmpc.forum_id = hm.start_id AND fmpc.member_id = fr.friend_id
  GROUP BY hm.start_id
)
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties, '"title"'::ag_catalog.agtype]) AS forumTitle,
  a.postCount
FROM agg a
JOIN ldbc_snb."Forum" f ON f.id = a.forum_id
ORDER BY a.postCount DESC,
         (CAST(ag_catalog.agtype_object_field_text(f.properties, 'id') AS bigint)) ASC
LIMIT 20;
