-- LdbcUpdate4AddForum — create a Forum vertex with HAS_MODERATOR + HAS_TAG edges.
--
-- Cypher-only: a single CREATE call. No side tables maintained — IC5 reads
-- forum.title and forum.id directly from the Cypher block's RETURN.

SELECT * FROM cypher('$graphName', $$
  MATCH (mod:Person {id: $moderatorPersonId})
  CREATE (f:Forum {id: $forumId, title: $forumTitle, creationDate: $creationDate})-[:HAS_MODERATOR]->(mod)
  WITH f
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (f)-[:HAS_TAG]->(t)
  RETURN count(f)
$$) AS (result agtype);
