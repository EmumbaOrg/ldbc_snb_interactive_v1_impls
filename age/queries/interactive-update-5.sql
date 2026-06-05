-- LdbcUpdate5AddForumMembership — adds a person as a forum member.
-- Cypher-only: a single call, no side tables maintained. IC5 reads m.joinDate
-- directly from the HAS_MEMBER edge (MATCH (forum:Forum)-[m:HAS_MEMBER]->(friend)
-- WHERE m.joinDate > $minDate).

SELECT * FROM cypher('$graphName', $$
  MATCH (forum:Forum {id: $forumId}), (person:Person {id: $personId})
  CREATE (forum)-[:HAS_MEMBER {joinDate: $joinDate}]->(person)
  RETURN count(*)
$$) AS (result agtype);
