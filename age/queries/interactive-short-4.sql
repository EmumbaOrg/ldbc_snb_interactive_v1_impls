SET search_path = ag_catalog, public;
SELECT messageCreationDate, messageContent FROM (
  SELECT messageCreationDate, messageContent
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})
    RETURN m.creationDate AS messageCreationDate, m.content AS messageContent
  $$) AS (messageCreationDate agtype, messageContent agtype)

  UNION ALL

  SELECT messageCreationDate, messageContent
  FROM cypher('$graphName', $$
    MATCH (m:Post {id: $messageId})
    RETURN m.creationDate AS messageCreationDate, coalesce(m.content, m.imageFile) AS messageContent
  $$) AS (messageCreationDate agtype, messageContent agtype)
) sub
LIMIT 1
