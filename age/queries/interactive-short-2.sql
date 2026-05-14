-- LdbcShortQuery2PersonPosts — top-10 recent messages by a person, each with its root-post author.
-- Hybrid: two Cypher calls (Comment branch + Post branch) traverse Person<-HAS_CREATOR-msg
-- (the natural graph shape — AGE-QUIRKS §3 forbids multi-label MATCH so the
-- Comment+Post split is required). Outer SQL merges the two branches, then
-- looks up the root post + author info from side tables only.
--
-- AGENTS.md §14 compliance: outer SQL only joins three non-AGE side tables
--   * CommentRootPost   — Comment business_id → root_post_business_id
--   * MessageByCreator  — message_business_id → creator_business_id (for the root post)
--   * PersonSide        — person_business_id → first_name, last_name
-- No outer-SQL read against any AGE label table.
--
-- This replaces the prior recursive-REPLY_OF + AGE-table-join shape that
-- joined Post, HAS_CREATOR, and Person directly in outer SQL (four §14
-- violations). CommentRootPost (extended with comment_business_id 2026-05-14)
-- replaces the recursive walk with a single PK lookup.

WITH user_top10 AS (
  SELECT * FROM (
    SELECT
      'C'::text                    AS mtype,
      (biz_id::text)::bigint       AS biz_id_bi,
      (cdate::text)::bigint        AS cdate_bi,
      content                      AS content_agt
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)
      RETURN msg.id          AS biz_id,
             msg.creationDate AS cdate,
             msg.content      AS content
      ORDER BY msg.creationDate DESC, msg.id ASC
      LIMIT 10
    $$) AS x(biz_id agtype, cdate agtype, content agtype)
    UNION ALL
    SELECT
      'P'::text,
      (biz_id::text)::bigint,
      (cdate::text)::bigint,
      content
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)
      RETURN msg.id          AS biz_id,
             msg.creationDate AS cdate,
             coalesce(msg.content, msg.imageFile) AS content
      ORDER BY msg.creationDate DESC, msg.id ASC
      LIMIT 10
    $$) AS y(biz_id agtype, cdate agtype, content agtype)
  ) merged
  ORDER BY cdate_bi DESC, biz_id_bi ASC
  LIMIT 10
)
SELECT
  ut.biz_id_bi::ag_catalog.agtype                                                AS messageId,
  ut.content_agt                                                                  AS messageContent,
  ut.cdate_bi::ag_catalog.agtype                                                  AS messageCreationDate,
  COALESCE(crp.root_post_business_id, ut.biz_id_bi)::ag_catalog.agtype            AS originalPostId,
  rp.creator_business_id::ag_catalog.agtype                                       AS originalPostAuthorId,
  ag_catalog.text_to_agtype(ps.first_name)                                        AS originalPostAuthorFirstName,
  ag_catalog.text_to_agtype(ps.last_name)                                         AS originalPostAuthorLastName
FROM user_top10 ut
LEFT JOIN ldbc_snb."CommentRootPost" crp
       ON ut.mtype = 'C' AND crp.comment_business_id = ut.biz_id_bi
JOIN ldbc_snb."MessageByCreator" rp
       ON rp.message_business_id = COALESCE(crp.root_post_business_id, ut.biz_id_bi)
      AND rp.is_post
JOIN ldbc_snb."PersonSide" ps
       ON ps.person_business_id = rp.creator_business_id
ORDER BY ut.cdate_bi DESC, ut.biz_id_bi ASC
LIMIT 10;
