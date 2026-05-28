-- LdbcQuery5 — Recent forums (joined after minDate) that 1- or 2-hop friends joined, with post counts.
-- Hybrid: Cypher fetches 1+2-hop friend+forum memberships (HAS_MEMBER edge
-- filtered by joinDate > $minDate) and projects forum scalar properties directly
-- (Phase A: HasMemberSide and ForumSide retired). Outer SQL aggregates over the
-- Cypher result and joins ForumMemberPostCount for the precomputed post count.
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11; IU8 stores both directions.
-- MATERIALIZED forces the planner to evaluate the friends+memberships set
-- before the FMPC join, preventing the AGE 1.6 threshold-flip at SF100+.
--
-- §14 compliance: ForumSide and HasMemberSide were §14-compliance workarounds
-- for trivial scalar property reads. Cypher RETURN of forum.title, forum.id,
-- and m.joinDate is the natural peer pattern — every peer reads Forum and
-- HAS_MEMBER properties directly (Phase A reword of §14).

WITH memberships AS MATERIALIZED (
  SELECT DISTINCT
         (friend_gid::text)::ag_catalog.graphid  AS friend_id,
         (forum_gid::text)::ag_catalog.graphid   AS forum_id,
         (forum_biz::text)::bigint               AS forum_business_id,
         forum_title::text                       AS forum_title
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    MATCH (forum:Forum)-[m:HAS_MEMBER]->(friend)
    WHERE m.joinDate > $minDate
    RETURN id(friend) AS friend_gid, id(forum) AS forum_gid, forum.id AS forum_biz, forum.title AS forum_title
    UNION ALL
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    MATCH (forum:Forum)-[m:HAS_MEMBER]->(friend)
    WHERE m.joinDate > $minDate
    RETURN id(friend) AS friend_gid, id(forum) AS forum_gid, forum.id AS forum_biz, forum.title AS forum_title
  $$) AS x(friend_gid agtype, forum_gid agtype, forum_biz agtype, forum_title agtype)
),
agg AS (
  SELECT mb.forum_id,
         mb.forum_business_id,
         mb.forum_title,
         COALESCE(SUM(fmpc.post_count), 0)::int AS postCount
  FROM memberships mb
  LEFT JOIN ldbc_snb."ForumMemberPostCount" fmpc
    ON fmpc.forum_id = mb.forum_id AND fmpc.member_id = mb.friend_id
  GROUP BY mb.forum_id, mb.forum_business_id, mb.forum_title
)
SELECT a.forum_title  AS forumTitle,
       a.postCount
FROM agg a
ORDER BY a.postCount DESC,
         a.forum_business_id ASC
LIMIT 20;
