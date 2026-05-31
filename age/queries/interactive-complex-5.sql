-- LdbcQuery5 — Recent forums (joined after minDate) that 1- or 2-hop friends joined, with post counts.
-- Hybrid: two Cypher arms (1-hop and 2-hop friends) each compute per-(friend, forum) post count
-- inline. Outer SQL sums pc per forum and returns top-20 by postCount DESC, forum.id ASC.
--
-- Milestone A 2026-05-30: ForumMemberPostCount retired. Count computed inline.
-- CORRECTNESS: the count MUST use staged `WITH DISTINCT friend, forum` BEFORE
-- `count(post)`. Without staging, a 2-hop friend reachable through K intermediaries
-- appears in K pre-aggregation rows, inflating count(post) by K×. Verified at SF3:
-- staged form gives correct results (matching prior FMPC values); naive form overcounts.
--
-- Shape per arm:
--   MATCH ...friends... MATCH (forum:Forum)-[m:HAS_MEMBER]->(friend) WHERE m.joinDate > $minDate
--   WITH DISTINCT friend, forum
--   OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)<-[:CONTAINER_OF]-(forum)
--   RETURN id(forum), forum.id, forum.title, count(post) AS pc
-- Outer SQL: UNION ALL both arms, GROUP BY forum, SUM(pc).
--
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11; IU8 stores both directions.
-- §14 compliance: Cypher RETURN of forum.title, forum.id scalar properties —
-- the natural peer pattern (Phase A: HasMemberSide and ForumSide retired).

WITH per_friend_forum AS MATERIALIZED (
  SELECT DISTINCT
    (friend_gid::text)::ag_catalog.graphid AS friend_id,
    (forum_gid::text)::ag_catalog.graphid  AS forum_id,
    (forum_biz::text)::bigint              AS forum_business_id,
    forum_title::text                      AS forum_title,
    (pc::text)::bigint                     AS pc
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    MATCH (forum:Forum)-[m:HAS_MEMBER]->(friend)
    WHERE m.joinDate > $minDate
    WITH DISTINCT friend, forum
    OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)<-[:CONTAINER_OF]-(forum)
    RETURN id(friend) AS friend_gid, id(forum) AS forum_gid, forum.id AS forum_biz, forum.title AS forum_title, count(post) AS pc
    UNION ALL
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    MATCH (forum:Forum)-[m:HAS_MEMBER]->(friend)
    WHERE m.joinDate > $minDate
    WITH DISTINCT friend, forum
    OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)<-[:CONTAINER_OF]-(forum)
    RETURN id(friend) AS friend_gid, id(forum) AS forum_gid, forum.id AS forum_biz, forum.title AS forum_title, count(post) AS pc
  $$) AS x(friend_gid agtype, forum_gid agtype, forum_biz agtype, forum_title agtype, pc agtype)
)
SELECT
  forum_title      AS forumTitle,
  SUM(pc)::int     AS postCount
FROM per_friend_forum
GROUP BY forum_id, forum_business_id, forum_title
ORDER BY SUM(pc) DESC,
         forum_business_id ASC
LIMIT 20;
