-- LdbcShortQuery2PersonPosts — top-10 recent messages by a person, each with its root-post author.
--
-- AGENTS.md §14 compliance: this query is pure SQL against three non-AGE
-- side tables. No outer-SQL reads or writes against any AGE label table.
--
-- Lookup chain:
--   1. MessageByCreator → top-10 messages by $personId, date-DESC + id ASC.
--   2. CommentRootPost (joined by comment_business_id) → root post for
--      each Comment; for messages where is_post=true the message itself is
--      the root.
--   3. MessageByCreator (joined by message_business_id = root_post_business_id)
--      → root post's creator_business_id.
--   4. PersonSide → root post author's first/last name.
--
-- Why this replaces the prior recursive-REPLY_OF + AGE-table-join shape:
--   * The previous query joined ldbc_snb."REPLY_OF", "Post", "HAS_CREATOR",
--     and "Person" directly in outer SQL — four §14 violations.
--   * CommentRootPost (extended with comment_business_id 2026-05-14) replaces
--     the recursive walk with a single PK lookup.
--   * MessageByCreator already mirrors every Comment+Post with creator info,
--     and PersonSide mirrors every Person's name.
--
-- This query is excluded from `age_parameterized_queries` (no cypher() calls,
-- so the prepareTemplate `$$, ?)` injection path has nothing to bind).
-- $personId is substituted as a literal at query-string-build time.

SELECT
  m.message_business_id::ag_catalog.agtype  AS messageId,
  ag_catalog.text_to_agtype(m.content)      AS messageContent,
  m.creation_date::ag_catalog.agtype        AS messageCreationDate,
  COALESCE(crp.root_post_business_id, m.message_business_id)::ag_catalog.agtype AS originalPostId,
  rp.creator_business_id::ag_catalog.agtype AS originalPostAuthorId,
  ag_catalog.text_to_agtype(ps.first_name)  AS originalPostAuthorFirstName,
  ag_catalog.text_to_agtype(ps.last_name)   AS originalPostAuthorLastName
FROM (
  SELECT message_business_id, creation_date, content, is_post
  FROM ldbc_snb."MessageByCreator"
  WHERE creator_business_id = $personId
  ORDER BY creation_date DESC, message_business_id ASC
  LIMIT 10
) m
LEFT JOIN ldbc_snb."CommentRootPost" crp
       ON NOT m.is_post AND crp.comment_business_id = m.message_business_id
JOIN ldbc_snb."MessageByCreator" rp
       ON rp.message_business_id = COALESCE(crp.root_post_business_id, m.message_business_id)
      AND rp.is_post
JOIN ldbc_snb."PersonSide" ps
       ON ps.person_business_id = rp.creator_business_id
ORDER BY m.creation_date DESC, m.message_business_id ASC
LIMIT 10;
