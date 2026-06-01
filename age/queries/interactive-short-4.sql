-- LdbcShortQuery4MessageContent — return creationDate and content of a message by id.
-- Hybrid: two Cypher calls (Comment branch, Post branch) UNION ALL'd with outer LIMIT 1
-- to short-circuit after the first non-empty arm. AGE has no multi-label MATCH (AGE-QUIRKS §3).
-- Anchor is `WHERE m.id = $messageId` so it binds the functional B-tree
-- idx_{comment,post}_id_agtype (verified Index Scan); the per-label content GINs were
-- retired — they tokenized free-text content/imageFile and blew up SF100 disk. See INDEXES.md.

SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Comment) WHERE m.id = $messageId
    RETURN m.creationDate, coalesce(m.content, m.imageFile)
  $$) AS (messageCreationDate agtype, messageContent agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Post) WHERE m.id = $messageId
    RETURN m.creationDate, coalesce(m.content, m.imageFile)
  $$) AS (messageCreationDate agtype, messageContent agtype)
) msg
LIMIT 1;
