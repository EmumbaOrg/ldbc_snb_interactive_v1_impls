-- LdbcQuery6 — Top-10 co-occurring tags on posts tagged with $tagName, among friends/FoF.
-- Hybrid: two Cypher calls (direct-friend branch, FoF branch) drive from the target Tag
-- vertex (gin_tag → 1 row) → HAS_TAG-tagged Post → HAS_CREATOR → creator, then verify
-- creator is reachable from the user via KNOWS. SQL aggregates postCount across branches.
-- IMPORTANT: explicit WITH between each MATCH segment is required — consecutive reverse-arrow
-- MATCHes in a single clause silently return 0 rows in AGE 1.6. Do NOT simplify these away.
-- Two-branch UNION ALL because AGE has no multi-label MATCH (AGE-QUIRKS §3).
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11.
-- TODO: if IC6 reappears in SF100+ profiling, file the chained-reverse-arrow bug upstream
--       and consider a denorm tag-pair side table at IU6 for O(1) co-occurrence lookup.

SELECT tagName, SUM(postCount::text::bigint)::bigint AS postCount FROM (
  -- Branch 1 (direct friends)
  SELECT * FROM cypher('$graphName', $$
    MATCH (target:Tag {name: $tagName})
    WITH target
    MATCH (post:Post)-[:HAS_TAG]->(target)
    WITH post, target
    MATCH (post)-[:HAS_CREATOR]->(creator:Person)
    WITH post, target, creator
    MATCH (creator)<-[:KNOWS]-(p:Person {id: $personId})
    WITH post, target
    MATCH (post)-[:HAS_TAG]->(tag:Tag)
    WHERE tag <> target
    WITH tag.name AS tagName, count(DISTINCT post) AS postCount
    RETURN tagName, postCount
    ORDER BY postCount DESC, tagName ASC
  $$) AS (tagName agtype, postCount agtype)
  UNION ALL
  -- Branch 2 (friends-of-friends, excluding direct)
  SELECT * FROM cypher('$graphName', $$
    MATCH (target:Tag {name: $tagName})
    WITH target
    MATCH (post:Post)-[:HAS_TAG]->(target)
    WITH post, target
    MATCH (post)-[:HAS_CREATOR]->(creator:Person)
    WHERE creator.id <> $personId
    WITH post, target, creator
    MATCH (creator)<-[:KNOWS]-(:Person)<-[:KNOWS]-(p:Person {id: $personId})
    WITH DISTINCT post, target, creator, p
    OPTIONAL MATCH (p)-[direct:KNOWS]->(creator)
    WITH post, target, direct
    WHERE direct IS NULL
    MATCH (post)-[:HAS_TAG]->(tag:Tag)
    WHERE tag <> target
    WITH tag.name AS tagName, count(DISTINCT post) AS postCount
    RETURN tagName, postCount
    ORDER BY postCount DESC, tagName ASC
  $$) AS (tagName agtype, postCount agtype)
) tags
GROUP BY tagName
ORDER BY SUM(postCount::text::bigint) DESC, tagName::text COLLATE "C" ASC
LIMIT 10;
