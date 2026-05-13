-- LdbcQuery5 — Recent forums (joined after minDate) that 1- or 2-hop friends joined, with post counts.
-- Hybrid: Cypher fetches 1+2-hop friend graphids via fixed-depth MATCH UNION
-- (no variable-length path per AGE-QUIRKS §4); outer SQL operates exclusively
-- on side tables, never on AGE-managed tables (client directive 2026-05-13):
--   HasMemberSide        — mirror of HAS_MEMBER (forum_id, member_id, join_date)
--   ForumMemberPostCount — precomputed (forum_id, member_id) → post_count
--   ForumSide            — mirror of Forum (forum_id, business_id, title)
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11; IU8 stores both directions.
-- Aggregation pre-groups by hms.forum_id (graphid scalar). MATERIALIZED forces
-- the planner to evaluate the friend set before the HasMemberSide join,
-- preventing the AGE 1.6 threshold-flip at SF100+ (sf3-final-report §5.1).

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
  SELECT hms.forum_id,
         COALESCE(SUM(fmpc.post_count), 0)::int AS postCount
  FROM friends fr
  JOIN ldbc_snb."HasMemberSide" hms
    ON hms.member_id = fr.friend_id
   AND hms.join_date > $minDate::bigint
  LEFT JOIN ldbc_snb."ForumMemberPostCount" fmpc
    ON fmpc.forum_id = hms.forum_id AND fmpc.member_id = fr.friend_id
  GROUP BY hms.forum_id
)
SELECT fs.title AS forumTitle,
       a.postCount
FROM agg a
JOIN ldbc_snb."ForumSide" fs ON fs.forum_id = a.forum_id
ORDER BY a.postCount DESC,
         fs.forum_business_id ASC
LIMIT 20;
