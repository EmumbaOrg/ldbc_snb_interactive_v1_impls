SET search_path = ag_catalog, public;
SELECT messageId, messageContent, messageCreationDate, originalPostId, originalPostAuthorId,
       originalPostAuthorFirstName, originalPostAuthorLastName
FROM (
  -- Person's Posts (the post IS the original post)
  SELECT messageId, messageContent, messageCreationDate, originalPostId,
         originalPostAuthorId, originalPostAuthorFirstName, originalPostAuthorLastName
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})<-[:HAS_CREATOR]-(post:Post)
    MATCH (post)-[:HAS_CREATOR]->(author:Person)
    RETURN
      post.id AS messageId,
      coalesce(post.imageFile, post.content) AS messageContent,
      post.creationDate AS messageCreationDate,
      post.id AS originalPostId,
      author.id AS originalPostAuthorId,
      author.firstName AS originalPostAuthorFirstName,
      author.lastName AS originalPostAuthorLastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)

  UNION ALL

  -- Person's Comments → resolve root post via REPLY_OF chain (1 hop)
  SELECT messageId, messageContent, messageCreationDate, originalPostId,
         originalPostAuthorId, originalPostAuthorFirstName, originalPostAuthorLastName
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(post:Post)
    MATCH (post)-[:HAS_CREATOR]->(author:Person)
    RETURN
      comment.id AS messageId,
      comment.content AS messageContent,
      comment.creationDate AS messageCreationDate,
      post.id AS originalPostId,
      author.id AS originalPostAuthorId,
      author.firstName AS originalPostAuthorFirstName,
      author.lastName AS originalPostAuthorLastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)

  UNION ALL

  -- Person's Comments → resolve root post via REPLY_OF chain (2 hops)
  SELECT messageId, messageContent, messageCreationDate, originalPostId,
         originalPostAuthorId, originalPostAuthorFirstName, originalPostAuthorLastName
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(post:Post)
    MATCH (post)-[:HAS_CREATOR]->(author:Person)
    RETURN
      comment.id AS messageId,
      comment.content AS messageContent,
      comment.creationDate AS messageCreationDate,
      post.id AS originalPostId,
      author.id AS originalPostAuthorId,
      author.firstName AS originalPostAuthorFirstName,
      author.lastName AS originalPostAuthorLastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)

  UNION ALL

  -- Person's Comments → resolve root post via REPLY_OF chain (3 hops)
  SELECT messageId, messageContent, messageCreationDate, originalPostId,
         originalPostAuthorId, originalPostAuthorFirstName, originalPostAuthorLastName
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(post:Post)
    MATCH (post)-[:HAS_CREATOR]->(author:Person)
    RETURN
      comment.id AS messageId,
      comment.content AS messageContent,
      comment.creationDate AS messageCreationDate,
      post.id AS originalPostId,
      author.id AS originalPostAuthorId,
      author.firstName AS originalPostAuthorFirstName,
      author.lastName AS originalPostAuthorLastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)

  UNION ALL

  -- Person's Comments → resolve root post via REPLY_OF chain (4 hops)
  SELECT messageId, messageContent, messageCreationDate, originalPostId,
         originalPostAuthorId, originalPostAuthorFirstName, originalPostAuthorLastName
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(post:Post)
    MATCH (post)-[:HAS_CREATOR]->(author:Person)
    RETURN
      comment.id AS messageId,
      comment.content AS messageContent,
      comment.creationDate AS messageCreationDate,
      post.id AS originalPostId,
      author.id AS originalPostAuthorId,
      author.firstName AS originalPostAuthorFirstName,
      author.lastName AS originalPostAuthorLastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)

  UNION ALL

  -- Person's Comments → resolve root post via REPLY_OF chain (5 hops)
  SELECT messageId, messageContent, messageCreationDate, originalPostId,
         originalPostAuthorId, originalPostAuthorFirstName, originalPostAuthorLastName
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(post:Post)
    MATCH (post)-[:HAS_CREATOR]->(author:Person)
    RETURN
      comment.id AS messageId,
      comment.content AS messageContent,
      comment.creationDate AS messageCreationDate,
      post.id AS originalPostId,
      author.id AS originalPostAuthorId,
      author.firstName AS originalPostAuthorFirstName,
      author.lastName AS originalPostAuthorLastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)

  UNION ALL

  -- Person's Comments → resolve root post via REPLY_OF chain (6 hops)
  SELECT messageId, messageContent, messageCreationDate, originalPostId,
         originalPostAuthorId, originalPostAuthorFirstName, originalPostAuthorLastName
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(:Comment)-[:REPLY_OF]->(post:Post)
    MATCH (post)-[:HAS_CREATOR]->(author:Person)
    RETURN
      comment.id AS messageId,
      comment.content AS messageContent,
      comment.creationDate AS messageCreationDate,
      post.id AS originalPostId,
      author.id AS originalPostAuthorId,
      author.firstName AS originalPostAuthorFirstName,
      author.lastName AS originalPostAuthorLastName
  $$) AS (messageId agtype, messageContent agtype, messageCreationDate agtype,
          originalPostId agtype, originalPostAuthorId agtype,
          originalPostAuthorFirstName agtype, originalPostAuthorLastName agtype)
) sub
ORDER BY messageCreationDate DESC, messageId ASC
LIMIT 10
