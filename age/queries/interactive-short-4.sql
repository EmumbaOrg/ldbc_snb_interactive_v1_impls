SET search_path = ag_catalog, public;
SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})
    RETURN m.creationDate, coalesce(m.content, m.imageFile)
  $$) AS (messageCreationDate agtype, messageContent agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Post {id: $messageId})
    RETURN m.creationDate, coalesce(m.content, m.imageFile)
  $$) AS (messageCreationDate agtype, messageContent agtype)
) msg
LIMIT 1;
