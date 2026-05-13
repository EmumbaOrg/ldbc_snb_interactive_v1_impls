-- LdbcShortQuery3PersonFriends — list direct friends of a person, sorted by friendship date.
-- Pure Cypher: single MATCH (Person)-[:KNOWS]->(Person) with ORDER BY on the edge property.
-- Directed `-[:KNOWS]->` traversal per AGE-QUIRKS §11; IU8 stores both directions so all
-- friends are found via idx_knows_start without a full edge-table scan.
--
-- A1.IS3 attempt (2026-05-13) — tried UNION ALL of forward + reverse directed arms
-- to match Neo4j's undirected `-[:KNOWS]-` semantics. Result: 2× row count because
-- AGE stores KNOWS bidirectionally (Neo4j stores once). Net regression from 6 → 97
-- failures. Reverted. The 6 remaining IS3 failures have a different root cause than
-- naive direction mismatch; see Category B investigation in the validation report.

SELECT * FROM cypher('$graphName', $$
  MATCH (n:Person {id: $personId})-[r:KNOWS]->(friend:Person)
  RETURN friend.id, friend.firstName, friend.lastName, r.creationDate
  ORDER BY r.creationDate DESC, toInteger(friend.id) ASC
$$) AS (personId agtype, firstName agtype, lastName agtype, friendshipCreationDate agtype);
