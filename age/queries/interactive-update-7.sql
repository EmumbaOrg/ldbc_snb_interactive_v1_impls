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
-- Call 2: HAS_TAG batch (post-MVCC-window). DO NOT merge into Call 1 — MVCC split is
--         non-negotiable (AGE issue #1954 / AGENTS.md §11).
-- Call 3: MATCH Comment and RETURN content for the MessageByCreator INSERT.
--
-- Comment.creator_id is fully retired — IC12 was migrated to a Cypher-hybrid
-- that traverses (friend)<-[:HAS_CREATOR]-(comment)-[:REPLY_OF]->(post) directly.
-- Comment.reply_of_id is consumed only by deploy-time backfill; denormalize-schema.sql
-- was rewritten to traverse REPLY_OF directly, so IU7 no longer writes either column.
-- Comment.country_id was previously retired 2026-05-14.
--
-- AGENTS.md §14 compliance: outer SQL only reads/writes non-AGE side tables
--   * CommentRootPost  — graphid PK + comment_business_id + root_post_business_id
--   * MessageByCreator — creator_business_id + message_business_id + content
-- No outer-SQL reads or writes of AGE label tables (Comment, HAS_CREATOR, REPLY_OF, etc.).

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
-- ON CONFLICT DO NOTHING (no target column) catches violations on EITHER unique
-- index: comment_id (PK) AND idx_commentrootpost_business_id (UNIQUE on
-- comment_business_id). Targeting only comment_id missed the latter and surfaced
-- as "duplicate key value violates unique constraint" crashes during validation
-- (20 such crashes in a 3K-op SF3 LDBC slice on 2026-05-15). The duplicate
-- comment_business_id arises when AGE 1.6's MVCC retry path re-runs IU7 after
-- a partial-rollback condition where the first CREATE produced a new graphid
-- but the rollback didn't fully reset AGE's internal state, so the retry
-- creates a SECOND Comment vertex with the same business id (different graphid)
-- and the CRP insert conflicts on comment_business_id rather than comment_id.
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
ON CONFLICT DO NOTHING
;

SELECT * FROM cypher('$graphName', $$
  MATCH (comment:Comment {id: $commentId})
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (comment)-[:HAS_TAG]->(t)
  RETURN count(comment)
$$) AS (result agtype);

-- MessageByCreator: content + comment graphid sourced from a third Cypher
-- MATCH (the Comment is committed after Call 1) to avoid SQL substitution of
-- $content and to populate the message_id column (added 2026-05-15 so IC10
-- can JOIN HAS_TAG by graphid without reading the AGE Post table).
INSERT INTO ldbc_snb."MessageByCreator" (creator_business_id, message_business_id, message_id, creation_date, content, is_post)
SELECT
  $authorPersonId,
  $commentId,
  (comment_gid::text)::ag_catalog.graphid,
  $creationDate,
  content_agt::text,
  false
FROM cypher('$graphName', $$
  MATCH (c:Comment {id: $commentId})
  RETURN id(c) AS comment_gid, c.content AS content_agt
$$) AS (comment_gid ag_catalog.agtype, content_agt ag_catalog.agtype)
ON CONFLICT DO NOTHING
;
