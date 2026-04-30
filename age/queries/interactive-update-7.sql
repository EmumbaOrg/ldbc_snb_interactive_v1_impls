SET search_path = ag_catalog, public;
SELECT * FROM cypher('$graphName', $$
  MATCH (author:Person {id: $authorPersonId}),
        (country:Country {id: $countryId})
  CREATE (author)<-[:HAS_CREATOR]-(c:Comment {
    id: $commentId,
    creationDate: $creationDate,
    locationIP: '$locationIP',
    browserUsed: '$browserUsed',
    content: '$content',
    length: $length
  })
  CREATE (c)-[:IS_LOCATED_IN]->(country)
  WITH c
  OPTIONAL MATCH (post:Post {id: $replyToPostId})
  WHERE $replyToPostId <> -1
  CREATE (c)-[:REPLY_OF]->(post)
  WITH c
  OPTIONAL MATCH (comment:Comment {id: $replyToCommentId})
  WHERE $replyToCommentId <> -1
  CREATE (c)-[:REPLY_OF]->(comment)
  WITH c
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (c)-[:HAS_TAG]->(t)
  RETURN c.id AS result
$$) AS (result agtype)
