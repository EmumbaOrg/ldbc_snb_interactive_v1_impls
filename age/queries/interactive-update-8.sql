-- LdbcUpdate8AddFriendship — creates a bidirectional KNOWS relationship.
-- Pure Cypher: single MATCH + CREATE of both p1→p2 and p2→p1 KNOWS edges.
-- Bidirectional storage is required so that directed `-[:KNOWS]->` traversal
-- (used in IC5, IC9, IC10, IC11) finds all friends via idx_knows_start (AGE-QUIRKS §11).
-- No denorm side effects; no SQL maintenance needed.

SELECT * FROM cypher('$graphName', $$
  MATCH (p1:Person {id: $person1Id}), (p2:Person {id: $person2Id})
  CREATE (p1)-[:KNOWS {creationDate: $creationDate}]->(p2),
         (p2)-[:KNOWS {creationDate: $creationDate}]->(p1)
  RETURN count(*)
$$) AS (result agtype);
