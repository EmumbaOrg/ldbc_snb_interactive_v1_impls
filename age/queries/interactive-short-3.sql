-- LdbcShortQuery3PersonFriends — list direct friends of a person, sorted by friendship date.
-- Pure Cypher: single MATCH (Person)-[:KNOWS]->(Person) with ORDER BY on the edge property.
-- Directed `-[:KNOWS]->` traversal per AGE-QUIRKS §11; IU8 stores both directions so all
-- friends are found via idx_knows_start without a full edge-table scan.
--
-- Do NOT UNION forward + reverse KNOWS arms to mimic Neo4j's undirected `-[:KNOWS]-`:
-- AGE stores KNOWS bidirectionally (Neo4j stores once), so that doubles the row count.
-- Directed single-arm traversal is correct here.

SELECT * FROM cypher('$graphName', $$
  MATCH (n:Person {id: $personId})-[r:KNOWS]->(friend:Person)
  RETURN friend.id, friend.firstName, friend.lastName, r.creationDate
  ORDER BY r.creationDate DESC, toInteger(friend.id) ASC
$$) AS (personId agtype, firstName agtype, lastName agtype, friendshipCreationDate agtype);
