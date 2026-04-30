SET search_path = ag_catalog, public;
SELECT * FROM (
  -- Comments by friends
  SELECT personId, personFirstName, personLastName, postOrCommentId, postOrCommentContent, postOrCommentCreationDate
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})-[:KNOWS]-(friend:Person)<-[:HAS_CREATOR]-(comment:Comment)
    WHERE comment.creationDate < $maxDate
    RETURN
      friend.id AS personId,
      friend.firstName AS personFirstName,
      friend.lastName AS personLastName,
      comment.id AS postOrCommentId,
      comment.content AS postOrCommentContent,
      comment.creationDate AS postOrCommentCreationDate
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          postOrCommentId agtype, postOrCommentContent agtype, postOrCommentCreationDate agtype)

  UNION ALL

  -- Posts by friends
  SELECT personId, personFirstName, personLastName, postOrCommentId, postOrCommentContent, postOrCommentCreationDate
  FROM cypher('$graphName', $$
    MATCH (:Person {id: $personId})-[:KNOWS]-(friend:Person)<-[:HAS_CREATOR]-(post:Post)
    WHERE post.creationDate < $maxDate
    RETURN
      friend.id AS personId,
      friend.firstName AS personFirstName,
      friend.lastName AS personLastName,
      post.id AS postOrCommentId,
      coalesce(post.content, post.imageFile) AS postOrCommentContent,
      post.creationDate AS postOrCommentCreationDate
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          postOrCommentId agtype, postOrCommentContent agtype, postOrCommentCreationDate agtype)
) sub
ORDER BY postOrCommentCreationDate DESC, postOrCommentId ASC
LIMIT 20
