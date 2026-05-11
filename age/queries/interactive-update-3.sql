-- LdbcUpdate3AddLikeComment — person likes a comment.
-- Pure Cypher: single MATCH + CREATE of a LIKES edge (person→comment).
-- No denorm side effects; no SQL maintenance needed.

SELECT * FROM cypher('$graphName', $$
  MATCH (person:Person {id: $personId}), (comment:Comment {id: $commentId})
  CREATE (person)-[:LIKES {creationDate: $creationDate}]->(comment)
  RETURN count(*)
$$) AS (result agtype);
