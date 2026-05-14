-- LdbcUpdate7AddComment — create a Comment vertex with HAS_CREATOR/REPLY_OF/IS_LOCATED_IN/HAS_TAG edges
-- and maintain the CommentRootPost + MessageByCreator side tables.
--
-- Three Cypher calls. Splitting Cypher across statements is required by the
-- AGE 1.6 MVCC concurrency trigger (see AGE-1.6-MVCC-BUG.md): HAS_TAG must
-- run in a fresh visibility window after the Comment is committed. The
-- MessageByCreator content lookup is a third call so the outer SQL never
-- reads the AGE Comment label table for $content (which arrives in
-- Cypher-style backslash-escaped form unsuitable for a SQL VALUES clause).
--
-- Call 1: CREATE Comment + HAS_CREATOR + REPLY_OF + IS_LOCATED_IN. Returns:
--           * id(comment)                — new comment's graphid (CommentRootPost.comment_id)
--           * rp.id when parent is Post  — root post business id; NULL/empty when parent is Comment
--         The CommentRootPost INSERT runs in the same SQL statement via a
--         WITH CTE: if Cypher said the parent was a Post, root = $replyToId;
--         otherwise we look up the parent Comment's existing CommentRootPost
--         row by comment_business_id.
-- Call 2: HAS_TAG batch (post-MVCC-window).
-- Call 3: MATCH Comment and RETURN content for the MessageByCreator INSERT.
--
-- SQL UPDATE keeps the still-live Comment.creator_id and Comment.reply_of_id
-- denorm columns (IC12 reads them). Comment.country_id retired 2026-05-14.

WITH new_comment AS (
  SELECT
    (new_gid::text)::ag_catalog.graphid                       AS new_comment_gid,
    NULLIF(parent_post_bid_agt::text, '')::bigint             AS parent_post_business_id
  FROM cypher('$graphName', $$
    MATCH (author:Person {id: $authorPersonId}),
          (country:Country {id: $countryId})
    OPTIONAL MATCH (rp:Post    {id: $replyToId})
    OPTIONAL MATCH (rc:Comment {id: $replyToId})
    WITH author, country, rp, coalesce(rp, rc) AS replyTo
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
    RETURN id(comment) AS new_gid,
           CASE WHEN rp IS NOT NULL THEN rp.id ELSE '' END AS parent_post_bid_agt
  $$) AS x(new_gid ag_catalog.agtype, parent_post_bid_agt ag_catalog.agtype)
)
INSERT INTO ldbc_snb."CommentRootPost" (comment_id, comment_business_id, root_post_business_id)
SELECT
  nc.new_comment_gid,
  $commentId,
  COALESCE(
    nc.parent_post_business_id,
    (SELECT crp.root_post_business_id
       FROM ldbc_snb."CommentRootPost" crp
      WHERE crp.comment_business_id = $replyToId)
  )
FROM new_comment nc
ON CONFLICT (comment_id) DO NOTHING
;

SELECT * FROM cypher('$graphName', $$
  MATCH (comment:Comment {id: $commentId})
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (comment)-[:HAS_TAG]->(t)
  RETURN count(comment)
$$) AS (result agtype);

-- Comment.country_id retired 2026-05-14: no read consumers (see SCHEMA.md).
-- creator_id and reply_of_id remain — IC12 reads them.
UPDATE ldbc_snb."Comment" c
   SET creator_id  = (SELECT end_id FROM ldbc_snb."HAS_CREATOR" WHERE start_id = c.id LIMIT 1),
       reply_of_id = (SELECT end_id FROM ldbc_snb."REPLY_OF"    WHERE start_id = c.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint) = $commentId
;

-- MessageByCreator: content sourced from a third Cypher MATCH (the Comment
-- is committed after Call 1) to avoid SQL substitution of $content.
INSERT INTO ldbc_snb."MessageByCreator" (creator_business_id, message_business_id, creation_date, content, is_post)
SELECT
  $authorPersonId,
  $commentId,
  $creationDate,
  content_agt::text,
  false
FROM cypher('$graphName', $$
  MATCH (c:Comment {id: $commentId})
  RETURN c.content AS content_agt
$$) AS (content_agt ag_catalog.agtype)
ON CONFLICT DO NOTHING
;
