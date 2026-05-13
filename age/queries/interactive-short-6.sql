-- LdbcShortQuery6MessageForum — return the containing forum and moderator for a message.
--
-- DIRECTIVE CARRYOVER (2026-05-13): this query violates the "no direct AGE-table
-- access in outer SQL" client directive (accesses Post, Comment, REPLY_OF,
-- CONTAINER_OF, Forum, HAS_MODERATOR, Person directly). A side-table rewrite
-- using CommentRootPost was attempted on 2026-05-13 and blocked by AGE 1.6:
-- `cypher()`'s third argument must be a `?` parameter, not a runtime SQL
-- expression, so the resolved root_post_id can't be passed into a second
-- cypher() call from a CTE/LATERAL. The CommentRootPost side table is kept in
-- denormalize-schema.sql as prep work for a future migration that needs either
-- (a) a heavier denorm extending CommentRootPost with forum + moderator
-- columns, or (b) AGE 1.7 (which relaxes the third-arg parameter restriction).
--
-- Structurally pure SQL — no Cypher calls. This is intentional, not an oversight:
--   1. REPLY_OF chain walk (Comment → root Post) must be SQL because AGE variable-length
--      paths hit an untyped-intermediate seq-scan pathology (AGE-QUIRKS §4, §9).
--      AGE 1.6 also fails with "Invalid number of attributes for ldbc_snb.Person"
--      when `*1..N` traverses through label tables that have denorm columns.
--   2. Trailing Forum+HAS_MODERATOR+Person lookup is 3 indexed B-tree JOINs on known
--      graphids — adding a Cypher block would add per-call overhead with zero graph-identity
--      benefit. Do NOT convert this query to a Cypher call in future passes.

WITH RECURSIVE
  post_seed AS MATERIALIZED (
    SELECT p.id AS post_id
    FROM ldbc_snb."Post" p
    WHERE CAST(ag_catalog.agtype_object_field_text(p.properties, 'id') AS bigint) = $messageId
  ),
  -- Skip the Comment seed (and the recursive walk) when the input is a Post.
  -- LDBC datagen guarantees Message ids are disjoint between Post and Comment,
  -- so at most one seed is non-empty.
  comment_seed AS MATERIALIZED (
    SELECT c.id AS vid
    FROM ldbc_snb."Comment" c
    WHERE NOT EXISTS (SELECT 1 FROM post_seed)
      AND CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint) = $messageId
  ),
  -- Walk REPLY_OF up to depth 20 (LDBC reply chains are bounded ~8 across all SFs).
  -- Each step is one indexed lookup on idx_replyof_start.
  walk AS (
    SELECT r.start_id, r.end_id, 1 AS depth
    FROM ldbc_snb."REPLY_OF" r
    JOIN comment_seed s ON r.start_id = s.vid
    UNION ALL
    SELECT r.start_id, r.end_id, w.depth + 1
    FROM walk w
    JOIN ldbc_snb."REPLY_OF" r ON r.start_id = w.end_id
    WHERE w.depth < 20
  ),
  -- The walk's deepest end_id is the rootPost (Posts have no outgoing REPLY_OF).
  root_post AS (
    SELECT post_id FROM post_seed
    UNION ALL
    (SELECT end_id FROM walk ORDER BY depth DESC LIMIT 1)
  )
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties,   '"id"'::ag_catalog.agtype])        AS forumId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties,   '"title"'::ag_catalog.agtype])     AS forumTitle,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"id"'::ag_catalog.agtype])        AS moderatorId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"firstName"'::ag_catalog.agtype]) AS moderatorFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"lastName"'::ag_catalog.agtype])  AS moderatorLastName
FROM root_post rp
JOIN ldbc_snb."CONTAINER_OF"  co  ON co.end_id   = rp.post_id
JOIN ldbc_snb."Forum"         f   ON f.id        = co.start_id
JOIN ldbc_snb."HAS_MODERATOR" hm  ON hm.start_id = f.id
JOIN ldbc_snb."Person"        per ON per.id      = hm.end_id
LIMIT 1;
