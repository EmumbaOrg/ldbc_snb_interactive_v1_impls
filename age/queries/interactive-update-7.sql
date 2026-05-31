-- LdbcUpdate7AddComment — create a Comment vertex with HAS_CREATOR/REPLY_OF/IS_LOCATED_IN/HAS_TAG edges.
--
-- Three Cypher calls. Splitting Cypher across statements is required by the
-- AGE 1.6 MVCC concurrency trigger (see AGE-1.6-MVCC-BUG.md): HAS_TAG must
-- run in a fresh visibility window after the Comment is committed.
--
-- Milestone A 2026-05-30: CommentRootPost and MessageByCreator retired.
-- Call 1 now just creates the Comment (no CRP INSERT afterward).
-- Call 2 still runs HAS_TAG in its own MVCC window (non-negotiable per §11).
-- Call 3 is dropped: no MessageByCreator INSERT needed.
-- IU7 is now two calls (down from three).
--
-- Comment.creator_id/reply_of_id/country_id: all previously retired 2026-05-14.

-- Call 1: CREATE Comment + HAS_CREATOR + REPLY_OF + IS_LOCATED_IN.
SELECT * FROM cypher('$graphName', $$
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
  RETURN count(*)
$$) AS (result agtype);

-- Call 2: HAS_TAG batch (post-MVCC-window). DO NOT merge into Call 1 —
-- MVCC split is non-negotiable (AGE issue #1954 / CLAUDE.md §11).
SELECT * FROM cypher('$graphName', $$
  MATCH (comment:Comment {id: $commentId})
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (comment)-[:HAS_TAG]->(t)
  RETURN count(comment)
$$) AS (result agtype);
