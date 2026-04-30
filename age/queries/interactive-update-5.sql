SET search_path = ag_catalog, public;
SELECT * FROM cypher('$graphName', $$
  MATCH (f:Forum {id: $forumId}), (p:Person {id: $personId})
  CREATE (f)-[:HAS_MEMBER {joinDate: $joinDate}]->(p)
  RETURN f.id AS result
$$) AS (result agtype)
