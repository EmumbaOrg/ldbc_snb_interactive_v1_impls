SET search_path = ag_catalog, public;
SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)
    WITH msg ORDER BY msg.creationDate DESC, msg.id ASC LIMIT 10
    MATCH (msg)-[:REPLY_OF]->(r1)
    OPTIONAL MATCH (r1)-[:REPLY_OF]->(r2)
    OPTIONAL MATCH (r2)-[:REPLY_OF]->(r3)
    OPTIONAL MATCH (r3)-[:REPLY_OF]->(r4)
    OPTIONAL MATCH (r4)-[:REPLY_OF]->(r5)
    OPTIONAL MATCH (r5)-[:REPLY_OF]->(r6)
    OPTIONAL MATCH (r6)-[:REPLY_OF]->(r7)
    OPTIONAL MATCH (r7)-[:REPLY_OF]->(r8)
    WITH msg, coalesce(r8, r7, r6, r5, r4, r3, r2, r1) AS rootPost
    MATCH (post:Post)-[:HAS_CREATOR]->(author:Person)
    WHERE id(post) = id(rootPost)
    RETURN msg.id, coalesce(msg.content, msg.imageFile), msg.creationDate,
           post.id, author.id, author.firstName, author.lastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)
    WITH msg ORDER BY msg.creationDate DESC, msg.id ASC LIMIT 10
    MATCH (msg)-[:HAS_CREATOR]->(author:Person)
    RETURN msg.id, coalesce(msg.content, msg.imageFile), msg.creationDate,
           msg.id, author.id, author.firstName, author.lastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)
) all_msgs
ORDER BY messageCreationDate DESC, messageId ASC
LIMIT 10;
