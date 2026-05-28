-- LdbcUpdate5AddForumMembership — adds a person as a forum member.
-- Phase A 2026-05-28: HasMemberSide retired. IC5 now reads m.joinDate directly
-- from the Cypher block (MATCH (forum:Forum)-[m:HAS_MEMBER]->(friend) WHERE
-- m.joinDate > $minDate). IU5 is now a single pure-Cypher call with no outer
-- SQL side-table write.
--
-- Cypher-only: one call, no outer SQL INSERT needed.

SELECT * FROM cypher('$graphName', $$
  MATCH (forum:Forum {id: $forumId}), (person:Person {id: $personId})
  CREATE (forum)-[:HAS_MEMBER {joinDate: $joinDate}]->(person)
  RETURN count(*)
$$) AS (result agtype);
