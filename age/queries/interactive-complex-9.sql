SET search_path = ag_catalog, public;
SELECT personId, personFirstName, personLastName, messageId, messageContent, messageCreationDate
FROM (
  -- Comments by friends/friends-of-friends
  SELECT personId, personFirstName, personLastName, messageId, messageContent, messageCreationDate
  FROM cypher('$graphName', $$
    MATCH (root:Person {id: $personId})-[:KNOWS*1..2]-(friend:Person)
    WHERE root <> friend
    WITH DISTINCT friend
    MATCH (friend)<-[:HAS_CREATOR]-(comment:Comment)
    WHERE comment.creationDate < $maxDate
    RETURN friend.id AS personId, friend.firstName AS personFirstName, friend.lastName AS personLastName,
           comment.id AS messageId, comment.content AS messageContent, comment.creationDate AS messageCreationDate
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          messageId agtype, messageContent agtype, messageCreationDate agtype)

  UNION ALL

  -- Posts by friends/friends-of-friends
  SELECT personId, personFirstName, personLastName, messageId, messageContent, messageCreationDate
  FROM cypher('$graphName', $$
    MATCH (root:Person {id: $personId})-[:KNOWS*1..2]-(friend:Person)
    WHERE root <> friend
    WITH DISTINCT friend
    MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
    WHERE post.creationDate < $maxDate
    RETURN friend.id AS personId, friend.firstName AS personFirstName, friend.lastName AS personLastName,
           post.id AS messageId, coalesce(post.content, post.imageFile) AS messageContent, post.creationDate AS messageCreationDate
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          messageId agtype, messageContent agtype, messageCreationDate agtype)
) sub
ORDER BY messageCreationDate DESC, messageId ASC
LIMIT 20
