-- LdbcShortQuery7MessageReplies — list direct replies to a message with knows-flag per author.
-- Hybrid: two Cypher calls (Comment seed branch, Post seed branch) UNION ALL'd in SQL with
-- outer ORDER BY (no LIMIT). AGE has no multi-label MATCH (AGE-QUIRKS §3); ORDER BY inside
-- each Cypher block is safe as a final RETURN ORDER — no mid-query LIMIT follows.
-- OPTIONAL MATCH (orig)-[:KNOWS]->(author) uses directed KNOWS per AGE-QUIRKS §11.

SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Comment)<-[:REPLY_OF]-(reply:Comment)-[:HAS_CREATOR]->(author:Person)
    WHERE m.id = $messageId
    OPTIONAL MATCH (m)-[:HAS_CREATOR]->(orig:Person)-[:KNOWS]->(author)
    RETURN reply.id, reply.content, reply.creationDate, author.id, author.firstName, author.lastName,
           orig IS NOT NULL
    ORDER BY reply.creationDate DESC, toInteger(author.id) ASC
  $$) AS (commentId agtype, commentContent agtype, commentCreationDate agtype,
          replyAuthorId agtype, replyAuthorFirstName agtype, replyAuthorLastName agtype,
          replyAuthorKnowsOriginalMessageAuthor agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Post)<-[:REPLY_OF]-(reply:Comment)-[:HAS_CREATOR]->(author:Person)
    WHERE m.id = $messageId
    OPTIONAL MATCH (m)-[:HAS_CREATOR]->(orig:Person)-[:KNOWS]->(author)
    RETURN reply.id, reply.content, reply.creationDate, author.id, author.firstName, author.lastName,
           orig IS NOT NULL
    ORDER BY reply.creationDate DESC, toInteger(author.id) ASC
  $$) AS (commentId agtype, commentContent agtype, commentCreationDate agtype,
          replyAuthorId agtype, replyAuthorFirstName agtype, replyAuthorLastName agtype,
          replyAuthorKnowsOriginalMessageAuthor agtype)
) replies
ORDER BY commentCreationDate DESC, replyAuthorId ASC;
