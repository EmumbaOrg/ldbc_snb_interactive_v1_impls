-- LdbcUpdate2AddLikePost — person likes a post.
-- Pure Cypher: single MATCH + CREATE of a LIKES edge (person→post).
-- No denorm side effects; no SQL maintenance needed.

SELECT * FROM cypher('$graphName', $$
  MATCH (person:Person {id: $personId}), (post:Post {id: $postId})
  CREATE (person)-[:LIKES {creationDate: $creationDate}]->(post)
  RETURN count(*)
$$) AS (result agtype);
