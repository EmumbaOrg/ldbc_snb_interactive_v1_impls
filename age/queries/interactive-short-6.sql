SET search_path = ag_catalog, public;
SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName FROM (
  -- Message is a Post directly
  SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
  FROM cypher('$graphName', $$
    MATCH (m:Post {id: $messageId})<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN f.id AS forumId, f.title AS forumTitle, mod.id AS moderatorId,
           mod.firstName AS moderatorFirstName, mod.lastName AS moderatorLastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype, moderatorFirstName agtype, moderatorLastName agtype)

  UNION ALL

  -- Message is a Comment → 1-hop REPLY_OF to Post
  SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(p:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN f.id AS forumId, f.title AS forumTitle, mod.id AS moderatorId,
           mod.firstName AS moderatorFirstName, mod.lastName AS moderatorLastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype, moderatorFirstName agtype, moderatorLastName agtype)

  UNION ALL

  -- Message is a Comment → 2-hop REPLY_OF chain to Post
  SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(p:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN f.id AS forumId, f.title AS forumTitle, mod.id AS moderatorId,
           mod.firstName AS moderatorFirstName, mod.lastName AS moderatorLastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype, moderatorFirstName agtype, moderatorLastName agtype)

  UNION ALL

  -- Message is a Comment → 3-hop REPLY_OF chain to Post
  SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(p:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN f.id AS forumId, f.title AS forumTitle, mod.id AS moderatorId,
           mod.firstName AS moderatorFirstName, mod.lastName AS moderatorLastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype, moderatorFirstName agtype, moderatorLastName agtype)

  UNION ALL

  -- Message is a Comment → 4-hop REPLY_OF chain to Post
  SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(p:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN f.id AS forumId, f.title AS forumTitle, mod.id AS moderatorId,
           mod.firstName AS moderatorFirstName, mod.lastName AS moderatorLastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype, moderatorFirstName agtype, moderatorLastName agtype)

  UNION ALL

  -- Message is a Comment → 5-hop REPLY_OF chain to Post
  SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(p:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN f.id AS forumId, f.title AS forumTitle, mod.id AS moderatorId,
           mod.firstName AS moderatorFirstName, mod.lastName AS moderatorLastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype, moderatorFirstName agtype, moderatorLastName agtype)

  UNION ALL

  -- Message is a Comment → 6-hop REPLY_OF chain to Post
  SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(p:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN f.id AS forumId, f.title AS forumTitle, mod.id AS moderatorId,
           mod.firstName AS moderatorFirstName, mod.lastName AS moderatorLastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype, moderatorFirstName agtype, moderatorLastName agtype)
) sub
LIMIT 1
