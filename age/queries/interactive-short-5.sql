SET search_path = ag_catalog, public;
SELECT personId, firstName, lastName FROM (
  SELECT personId, firstName, lastName
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:HAS_CREATOR]->(p:Person)
    RETURN p.id AS personId, p.firstName AS firstName, p.lastName AS lastName
  $$) AS (personId agtype, firstName agtype, lastName agtype)

  UNION ALL

  SELECT personId, firstName, lastName
  FROM cypher('$graphName', $$
    MATCH (m:Post {id: $messageId})-[:HAS_CREATOR]->(p:Person)
    RETURN p.id AS personId, p.firstName AS firstName, p.lastName AS lastName
  $$) AS (personId agtype, firstName agtype, lastName agtype)
) sub
LIMIT 1
