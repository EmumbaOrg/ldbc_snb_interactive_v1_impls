-- LdbcUpdate4AddForum — create a Forum vertex with HAS_MODERATOR + HAS_TAG edges.
--
-- Phase A 2026-05-28: ForumSide retired. IC5 now reads forum.title and forum.id
-- directly from the Cypher block's RETURN. IU4 is simplified to one Cypher call.
--
-- Note: the two-step pattern (CREATE then MATCH) is no longer required now that
-- there is no side table INSERT to feed. The single CREATE call is sufficient.
-- The legacy Forum.moderator_id denorm UPDATE was removed previously; no other
-- side table is maintained by IU4.

SELECT * FROM cypher('$graphName', $$
  MATCH (mod:Person {id: $moderatorPersonId})
  CREATE (f:Forum {id: $forumId, title: $forumTitle, creationDate: $creationDate})-[:HAS_MODERATOR]->(mod)
  WITH f
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (f)-[:HAS_TAG]->(t)
  RETURN count(f)
$$) AS (result agtype);
