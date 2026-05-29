-- LdbcUpdate6AddPost — create a Post vertex with HAS_CREATOR/CONTAINER_OF/IS_LOCATED_IN/HAS_TAG edges.
-- Pure hybrid: two Cypher calls drive all writes. Zero outer-SQL reads or writes
-- of AGE label tables (CLAUDE.md §14).
--
-- Call 1: CREATE Post + all edges in one chained WITH/UNWIND block.
--         RETURN count(*) ensures exactly one output row even when $tagIds
--         is an empty list (UNWIND [] produces 0 rows; count(*) folds them
--         back to 1). This mirrors the IU1 safe-RETURN pattern.
-- Call 2: MATCH the just-created Post and RETURN id(forum), id(author), id(post),
--         and coalesce(post.content, post.imageFile). All side-table writes are
--         driven from this single MATCH via a writable CTE chain.
--
-- SQL maintains (all side tables — NO AGE label tables):
--   ForumMemberPostCount(forum_id, member_id)     (iter-2 aggregate)
--   MessageByCreator(creator_business_id, …, message_id)  (Phase C mirror)
--
-- PersonPostCount retired Phase B 2026-05-29: IU6 no longer increments a PPC
-- counter. IC10 computes total post count inline against MessageByCreator.
--
-- Post.forum_id retired 2026-05-14: forum gid sourced from Call 2 MATCH.
-- Post.creator_id retired 2026-05-15: IC10 was migrated to use
-- MessageByCreator.message_id for the HAS_TAG join, so the UPDATE Post SET
-- creator_id is gone. The column itself stays on disk as NULL (AGE 1.6 blocks
-- ALTER TABLE DROP COLUMN on label tables). idx_post_creator_id is dropped
-- by migration 2026-05-15-tier3b-drop-post-creator-id-usage.sql.

-- Call 1: CREATE Post + edges. count(*) always returns exactly 1 row.
SELECT * FROM cypher('$graphName', $$
  MATCH (author:Person {id: $authorPersonId}),
        (country:Country {id: $countryId}),
        (forum:Forum {id: $forumId})
  CREATE (post:Post {
    id: $postId,
    creationDate: $creationDate,
    locationIP: $locationIP,
    browserUsed: $browserUsed,
    language: $language,
    content: CASE $content WHEN '' THEN null ELSE $content END,
    imageFile: CASE $imageFile WHEN '' THEN null ELSE $imageFile END,
    length: $length
  })-[:HAS_CREATOR]->(author),
  (forum)-[:CONTAINER_OF]->(post),
  (post)-[:IS_LOCATED_IN]->(country)
  WITH post
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (post)-[:HAS_TAG]->(t)
  RETURN count(*)
$$) AS (result agtype);

-- Call 2: MATCH the committed Post; drive all side-table writes via a writable
-- CTE chain. PostgreSQL guarantees writable CTEs execute exactly once regardless
-- of whether the terminal DML references them.
-- DISTINCT + LIMIT 1 on post_data guards against pre-existing duplicate label
-- rows that would fan-out the Cypher CREATE into multiple Posts.
WITH post_data AS (
  SELECT
    (forum_gid::text)::ag_catalog.graphid  AS forum_gid,
    (author_gid::text)::ag_catalog.graphid AS author_gid,
    (post_gid::text)::ag_catalog.graphid   AS post_gid,
    content_agt::text                      AS content_text
  FROM cypher('$graphName', $$
    MATCH (forum:Forum)-[:CONTAINER_OF]->(post:Post {id: $postId})-[:HAS_CREATOR]->(author:Person)
    RETURN id(forum) AS forum_gid, id(author) AS author_gid, id(post) AS post_gid,
           coalesce(post.content, post.imageFile) AS content_agt
  $$) AS x(forum_gid ag_catalog.agtype, author_gid ag_catalog.agtype, post_gid ag_catalog.agtype, content_agt ag_catalog.agtype)
),
insert_fmpc AS (
  INSERT INTO ldbc_snb."ForumMemberPostCount" (forum_id, member_id, post_count)
  SELECT forum_gid, author_gid, 1
  FROM (SELECT DISTINCT forum_gid, author_gid FROM post_data LIMIT 1) ins
  ON CONFLICT (forum_id, member_id) DO UPDATE
     SET post_count = ldbc_snb."ForumMemberPostCount".post_count + 1
  RETURNING forum_id, member_id
)
-- Terminal DML: MessageByCreator append (now includes message_id graphid).
-- content_text has the JSON quotes already stripped by ::text cast above.
INSERT INTO ldbc_snb."MessageByCreator" (creator_business_id, message_business_id, message_id, creation_date, content, is_post)
SELECT
  $authorPersonId,
  $postId,
  pd.post_gid,
  $creationDate,
  pd.content_text,
  true
FROM post_data pd
ON CONFLICT DO NOTHING
;
