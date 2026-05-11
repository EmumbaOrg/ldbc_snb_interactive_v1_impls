-- LdbcUpdate7AddComment
--
-- Split into TWO cypher() calls to avoid the AGE MVCC concurrency trigger
-- documented in age/AGE-1.6-MVCC-BUG.md. The prior single-block form had:
--   (1) Untyped MATCH (replyTo {id: ...}) — AGE-QUIRKS §9 label-explosion,
--   (2) WITH comment + UNWIND $tagIds + CREATE (comment)-[:HAS_TAG]->(t) —
--       re-reads the just-created comment vertex per iteration inside the
--       same Cypher block, which under concurrency hits issue #1954
--       ("vertex assigned to variable comment was deleted").
-- Splitting into two cypher() calls puts the HAS_TAG fan-out in a fresh
-- transaction-visibility window where `comment` is already committed.
-- Also maintains Comment.creator_id, reply_of_id, country_id denorm columns.

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

UPDATE ldbc_snb."Comment" c
   SET creator_id  = (SELECT end_id FROM ldbc_snb."HAS_CREATOR" WHERE start_id = c.id LIMIT 1),
       reply_of_id = (SELECT end_id FROM ldbc_snb."REPLY_OF"    WHERE start_id = c.id LIMIT 1),
       country_id  = (SELECT end_id FROM ldbc_snb."IS_LOCATED_IN" WHERE start_id = c.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint) = $commentId
;
