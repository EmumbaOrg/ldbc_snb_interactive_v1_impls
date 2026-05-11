-- LdbcUpdate5AddForumMembership — adds a person as a forum member.
-- Pure Cypher: single MATCH + CREATE of a HAS_MEMBER edge (forum→person).
-- No denorm side effects; no SQL maintenance needed.

SELECT * FROM cypher('$graphName', $$
  MATCH (forum:Forum {id: $forumId}), (person:Person {id: $personId})
  CREATE (forum)-[:HAS_MEMBER {joinDate: $joinDate}]->(person)
  RETURN count(*)
$$) AS (result agtype);
