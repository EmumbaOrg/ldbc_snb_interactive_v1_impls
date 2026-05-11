-- LdbcShortQuery5MessageCreator — return the author of a given message.
-- Hybrid: two Cypher calls (Comment branch, Post branch) UNION ALL'd in SQL; outer LIMIT 1
-- short-circuits after the first non-empty arm. AGE has no multi-label MATCH (AGE-QUIRKS §3),
-- so Comment and Post are queried separately.

SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:HAS_CREATOR]->(p:Person)
    RETURN p.id, p.firstName, p.lastName
  $$) AS (personId agtype, firstName agtype, lastName agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Post {id: $messageId})-[:HAS_CREATOR]->(p:Person)
    RETURN p.id, p.firstName, p.lastName
  $$) AS (personId agtype, firstName agtype, lastName agtype)
) creator
LIMIT 1;
