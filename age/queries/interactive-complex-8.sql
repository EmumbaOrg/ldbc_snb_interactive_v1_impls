SET search_path = ag_catalog, public;
SELECT personId, personFirstName, personLastName, commentCreationDate, commentId, commentContent
FROM (
  -- Replies to Comments
  SELECT personId, personFirstName, personLastName, commentCreationDate, commentId, commentContent
  FROM cypher('$graphName', $$
    MATCH (start:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)<-[:REPLY_OF]-(comment:Comment)-[:HAS_CREATOR]->(person:Person)
    RETURN
      person.id AS personId,
      person.firstName AS personFirstName,
      person.lastName AS personLastName,
      comment.creationDate AS commentCreationDate,
      comment.id AS commentId,
      comment.content AS commentContent
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          commentCreationDate agtype, commentId agtype, commentContent agtype)

  UNION ALL

  -- Replies to Posts
  SELECT personId, personFirstName, personLastName, commentCreationDate, commentId, commentContent
  FROM cypher('$graphName', $$
    MATCH (start:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)<-[:REPLY_OF]-(comment:Comment)-[:HAS_CREATOR]->(person:Person)
    RETURN
      person.id AS personId,
      person.firstName AS personFirstName,
      person.lastName AS personLastName,
      comment.creationDate AS commentCreationDate,
      comment.id AS commentId,
      comment.content AS commentContent
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          commentCreationDate agtype, commentId agtype, commentContent agtype)
) sub
ORDER BY commentCreationDate DESC, commentId ASC
LIMIT 20
