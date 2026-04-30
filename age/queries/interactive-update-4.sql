SET search_path = ag_catalog, public;
SELECT * FROM cypher('$graphName', $$
  MATCH (p:Person {id: $moderatorPersonId})
  CREATE (f:Forum {id: $forumId, title: '$forumTitle', creationDate: $creationDate})-[:HAS_MODERATOR]->(p)
  WITH f
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (f)-[:HAS_TAG]->(t)
  RETURN f.id AS result
$$) AS (result agtype)
