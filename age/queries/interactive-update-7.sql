-- LdbcUpdate7AddComment — also maintains Comment.creator_id,
-- Comment.reply_of_id, Comment.country_id denorm columns.
SELECT * FROM cypher('$graphName', $$
  MATCH (author:Person {id: $authorPersonId}),
        (country:Country {id: $countryId}),
        (replyTo {id: $replyToId})
  CREATE (comment:Comment {
    id: $commentId,
    creationDate: $creationDate,
    locationIP: $locationIP,
    browserUsed: $browserUsed,
    content: $content,
    length: $length
  })-[:HAS_CREATOR]->(author),
  (comment)-[:REPLY_OF]->(replyTo),
  (comment)-[:IS_LOCATED_IN]->(country)
  WITH comment
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (comment)-[:HAS_TAG]->(t)
  RETURN count(comment)
$$) AS (result agtype);
UPDATE ldbc_snb."Comment" c
   SET creator_id  = (SELECT end_id FROM ldbc_snb."HAS_CREATOR" WHERE start_id = c.id LIMIT 1),
       reply_of_id = (SELECT end_id FROM ldbc_snb."REPLY_OF"    WHERE start_id = c.id LIMIT 1),
       country_id  = (SELECT end_id FROM ldbc_snb."IS_LOCATED_IN" WHERE start_id = c.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint) = $commentId
;
