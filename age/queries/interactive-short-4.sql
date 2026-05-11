-- LdbcShortQuery4MessageContent — return creationDate and content of a message by id.
-- Hybrid: two Cypher calls (Comment branch, Post branch) UNION ALL'd with outer LIMIT 1
-- to short-circuit after the first non-empty arm. AGE has no multi-label MATCH (AGE-QUIRKS §3).
-- Each Cypher call uses the per-label GIN index for the property MATCH; no denorm needed.

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
