-- LdbcUpdate7AddComment — create a Comment vertex with HAS_CREATOR/REPLY_OF/IS_LOCATED_IN/HAS_TAG edges.
-- Hybrid: TWO Cypher calls split to avoid the AGE MVCC concurrency trigger (see AGE-1.6-MVCC-BUG.md).
--   Call 1: creates Comment + HAS_CREATOR + REPLY_OF + IS_LOCATED_IN.
--   Call 2: MATCH existing Comment + UNWIND $tagIds + CREATE HAS_TAG — runs in a fresh
--           visibility window where the Comment is already committed, avoiding issue #1954.
-- Untyped MATCH avoided by using OPTIONAL MATCH (rp:Post) + OPTIONAL MATCH (rc:Comment) (AGE-QUIRKS §9).
-- SQL UPDATE maintains Comment.{creator_id, reply_of_id, country_id} (iter-1 column denorm).

SELECT * FROM cypher('$graphName', $$
  MATCH (author:Person {id: $authorPersonId}),
        (country:Country {id: $countryId})
  OPTIONAL MATCH (rp:Post {id: $replyToId})
  OPTIONAL MATCH (rc:Comment {id: $replyToId})
  WITH author, country, coalesce(rp, rc) AS replyTo
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
  RETURN count(comment)
$$) AS (result agtype);

SELECT * FROM cypher('$graphName', $$
  MATCH (comment:Comment {id: $commentId})
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (comment)-[:HAS_TAG]->(t)
  RETURN count(comment)
$$) AS (result agtype);

-- Comment.country_id retired 2026-05-14: no read consumers (see SCHEMA.md).
-- creator_id and reply_of_id are still live (IC12 + downstream CommentRootPost
-- maintenance).
UPDATE ldbc_snb."Comment" c
   SET creator_id  = (SELECT end_id FROM ldbc_snb."HAS_CREATOR" WHERE start_id = c.id LIMIT 1),
       reply_of_id = (SELECT end_id FROM ldbc_snb."REPLY_OF"    WHERE start_id = c.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint) = $commentId
;
-- MessageByCreator: append the new Comment for IC9's per-creator date-DESC walk.
-- Source content from the just-inserted Comment vertex (not via $content
-- substitution) to avoid the convertString() Cypher-vs-SQL escaping mismatch.
INSERT INTO ldbc_snb."MessageByCreator" (creator_business_id, message_business_id, creation_date, content, is_post)
SELECT
  $authorPersonId,
  $commentId,
  $creationDate,
  ag_catalog.agtype_object_field_text(c.properties, 'content'),
  false
FROM ldbc_snb."Comment" c
WHERE CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint) = $commentId
ON CONFLICT DO NOTHING
;
