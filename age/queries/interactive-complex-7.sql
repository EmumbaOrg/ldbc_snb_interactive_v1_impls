SET search_path = ag_catalog, public;
SELECT personId, personFirstName, personLastName, likeCreationDate, messageId, messageContent,
       ((likeCreationDate::text::bigint - messageCreationDate::text::bigint) / 60000)::int AS minutesLatency,
       NOT EXISTS (
         SELECT 1 FROM cypher('$graphName', $$
           MATCH (p:Person {id: $personId})-[:KNOWS]-(liker:Person)
           RETURN liker.id AS lid
         $$) AS (lid agtype)
         WHERE lid = sub.personId
       ) AS isNew
FROM (
  SELECT DISTINCT ON (personId)
    personId, personFirstName, personLastName, likeCreationDate, messageId, messageContent, messageCreationDate
  FROM (
    -- Likes on Comments
    SELECT personId, personFirstName, personLastName, likeCreationDate, messageId, messageContent,
           messageCreationDate
    FROM cypher('$graphName', $$
      MATCH (person:Person {id: $personId})<-[:HAS_CREATOR]-(comment:Comment)<-[l:LIKES]-(liker:Person)
      RETURN
        liker.id AS personId,
        liker.firstName AS personFirstName,
        liker.lastName AS personLastName,
        l.creationDate AS likeCreationDate,
        comment.id AS messageId,
        comment.content AS messageContent,
        comment.creationDate AS messageCreationDate
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, messageId agtype, messageContent agtype, messageCreationDate agtype)

    UNION ALL

    -- Likes on Posts
    SELECT personId, personFirstName, personLastName, likeCreationDate, messageId, messageContent,
           messageCreationDate
    FROM cypher('$graphName', $$
      MATCH (person:Person {id: $personId})<-[:HAS_CREATOR]-(post:Post)<-[l:LIKES]-(liker:Person)
      RETURN
        liker.id AS personId,
        liker.firstName AS personFirstName,
        liker.lastName AS personLastName,
        l.creationDate AS likeCreationDate,
        post.id AS messageId,
        coalesce(post.content, post.imageFile) AS messageContent,
        post.creationDate AS messageCreationDate
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, messageId agtype, messageContent agtype, messageCreationDate agtype)
  ) all_likes
  ORDER BY personId, likeCreationDate DESC, messageId ASC
) sub
ORDER BY likeCreationDate DESC, personId ASC
LIMIT 20
