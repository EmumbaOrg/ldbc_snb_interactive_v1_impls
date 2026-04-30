SET search_path = ag_catalog, public;
SELECT commentId, commentContent, commentCreationDate, replyAuthorId,
       replyAuthorFirstName, replyAuthorLastName, replyAuthorKnowsOriginalMessageAuthor
FROM (
  -- Replies to a Comment
  SELECT commentId, commentContent, commentCreationDate, replyAuthorId,
         replyAuthorFirstName, replyAuthorLastName, replyAuthorKnowsOriginalMessageAuthor
  FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})<-[:REPLY_OF]-(c:Comment)-[:HAS_CREATOR]->(p:Person)
    OPTIONAL MATCH (m)-[:HAS_CREATOR]->(a:Person)-[:KNOWS]-(p)
    RETURN
      c.id AS commentId,
      c.content AS commentContent,
      c.creationDate AS commentCreationDate,
      p.id AS replyAuthorId,
      p.firstName AS replyAuthorFirstName,
      p.lastName AS replyAuthorLastName,
      CASE WHEN a IS NOT NULL THEN true ELSE false END AS replyAuthorKnowsOriginalMessageAuthor
    ORDER BY commentCreationDate DESC, replyAuthorId ASC
  $$) AS (commentId agtype, commentContent agtype, commentCreationDate agtype,
          replyAuthorId agtype, replyAuthorFirstName agtype, replyAuthorLastName agtype,
          replyAuthorKnowsOriginalMessageAuthor agtype)

  UNION ALL

  -- Replies to a Post
  SELECT commentId, commentContent, commentCreationDate, replyAuthorId,
         replyAuthorFirstName, replyAuthorLastName, replyAuthorKnowsOriginalMessageAuthor
  FROM cypher('$graphName', $$
    MATCH (m:Post {id: $messageId})<-[:REPLY_OF]-(c:Comment)-[:HAS_CREATOR]->(p:Person)
    OPTIONAL MATCH (m)-[:HAS_CREATOR]->(a:Person)-[:KNOWS]-(p)
    RETURN
      c.id AS commentId,
      c.content AS commentContent,
      c.creationDate AS commentCreationDate,
      p.id AS replyAuthorId,
      p.firstName AS replyAuthorFirstName,
      p.lastName AS replyAuthorLastName,
      CASE WHEN a IS NOT NULL THEN true ELSE false END AS replyAuthorKnowsOriginalMessageAuthor
    ORDER BY commentCreationDate DESC, replyAuthorId ASC
  $$) AS (commentId agtype, commentContent agtype, commentCreationDate agtype,
          replyAuthorId agtype, replyAuthorFirstName agtype, replyAuthorLastName agtype,
          replyAuthorKnowsOriginalMessageAuthor agtype)
) sub
ORDER BY commentCreationDate DESC, replyAuthorId ASC
