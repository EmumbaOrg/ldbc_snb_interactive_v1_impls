-- LdbcShortQuery2PersonPosts
--
-- Why this is a hybrid SQL recursive CTE instead of an AGE Cypher call:
--   The original Cypher form (kept commented at the bottom) used:
--     1. `WITH msg ORDER BY ... LIMIT 10` inside Cypher — known to disable
--        AGE's parallel-append plan (see IC2 V2 regression on the same
--        pattern: 107→134 ms mean / 301→777 ms p99 at SF0.1).
--     2. An 8-deep `OPTIONAL MATCH (rN)-[:REPLY_OF]->(rN+1)` chain to walk
--        a Comment back to its root Post. AGE 1.6 plans each untyped
--        intermediate as a UNION ALL over every vertex label in the
--        graph, and the final `MATCH (p:Post) WHERE id(p) = id(rootPost)`
--        forces a full Seq Scan on Post even though the seed already
--        pinned a single graphid (the same SQ6-documented pathology).
--
--   Measured at SF3:
--     Original Cypher: ~7.5 s mean / ~18 s p99 / 933 calls = ~117 min
--                      (~38% of the 50 min benchmark wall time).
--     EXPLAIN shows `Seq Scan on "Post" post rows=2,595,655` per call.
--   At SF1000 the Post seq scan would be ~67 M rows and dominate everything.
--
-- The hybrid SQL form below sidesteps both pathologies:
--     - `user_top10` materialises the user's most-recent 10 messages
--       (Comment + Post UNION ALL) using `idx_hascreator_end` per label —
--       no Cypher LIMIT-inside-Cypher pessimisation.
--     - `reply_walk` recursive CTE walks REPLY_OF using `idx_replyof_start`
--       (B-tree). Walk naturally terminates AT the rootPost because Posts
--       have no outgoing REPLY_OF edges, so the deepest `end_id` IS the
--       rootPost. No join back to Post table required.
--     - `msg_root` picks the deepest end_id per message via window function.
--     - Final SELECT JOINs `user_top10` with `msg_root` (LEFT JOIN — Post
--       messages have no walk; root_gid falls back to the message itself).
--   All accesses use per-label graphid B-tree indexes (idx_*_graphid) and
--   are O(log N).
--
-- Output columns wrapped via `ag_catalog.agtype_access_operator` /
-- `agtype_object_field_text(...)::bigint::agtype` — same agtype shape
-- AGE Cypher RETURN produces, so AgeConverter sees agtype-typed values
-- exactly as before. No Java glue change required.
--
-- Same pattern that landed for SQ6 (interactive-short-6.sql).
--
-- Original Cypher implementation, kept for reference:
-- ----------------------------------------------------------------------------
-- SELECT * FROM (
--   SELECT * FROM cypher_DOLLAR_GRAPH$
--     MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)
--     WITH msg ORDER BY msg.creationDate DESC, msg.id ASC LIMIT 10
--     MATCH (msg)-[:REPLY_OF]->(r1)
--     OPTIONAL MATCH (r1)-[:REPLY_OF]->(r2)
--     ... (8 levels) ...
--     WITH msg, coalesce(r8, ..., r1) AS rootPost
--     MATCH (post:Post)-[:HAS_CREATOR]->(author:Person)
--     WHERE id(post) = id(rootPost)
--     RETURN msg.id, coalesce(msg.content, msg.imageFile), msg.creationDate,
--            post.id, author.id, author.firstName, author.lastName
--   $$ AS (...) UNION ALL
--   SELECT * FROM cypher_DOLLAR_GRAPH$
--     MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)
--     WITH msg ORDER BY msg.creationDate DESC, msg.id ASC LIMIT 10
--     MATCH (msg)-[:HAS_CREATOR]->(author:Person)
--     RETURN msg.id, coalesce(msg.content, msg.imageFile), msg.creationDate,
--            msg.id, author.id, author.firstName, author.lastName
--   $$ AS (...)
-- ) all_msgs ORDER BY messageCreationDate DESC, messageId ASC LIMIT 10
-- ----------------------------------------------------------------------------

WITH RECURSIVE
  user_gid AS MATERIALIZED (
    SELECT p.id
    FROM ldbc_snb."Person" p
    WHERE CAST(ag_catalog.agtype_object_field_text(p.properties, 'id') AS bigint) = $personId
  ),
  user_msgs_raw AS (
    SELECT m.id AS gid, 'C'::text AS mtype, m.properties AS props,
           CAST(ag_catalog.agtype_object_field_text(m.properties, 'creationDate') AS bigint) AS cdate,
           CAST(ag_catalog.agtype_object_field_text(m.properties, 'id') AS bigint) AS biz_id
    FROM ldbc_snb."HAS_CREATOR" hc
    JOIN user_gid u ON hc.end_id = u.id
    JOIN ldbc_snb."Comment" m ON m.id = hc.start_id
    UNION ALL
    SELECT m.id AS gid, 'P'::text AS mtype, m.properties AS props,
           CAST(ag_catalog.agtype_object_field_text(m.properties, 'creationDate') AS bigint) AS cdate,
           CAST(ag_catalog.agtype_object_field_text(m.properties, 'id') AS bigint) AS biz_id
    FROM ldbc_snb."HAS_CREATOR" hc
    JOIN user_gid u ON hc.end_id = u.id
    JOIN ldbc_snb."Post" m ON m.id = hc.start_id
  ),
  user_top10 AS MATERIALIZED (
    SELECT *
    FROM user_msgs_raw
    ORDER BY cdate DESC, biz_id ASC
    LIMIT 10
  ),
  -- Walk REPLY_OF up to depth 20 (LDBC reply chains are bounded ~8 across all SFs).
  -- Each step is one indexed lookup on idx_replyof_start.
  reply_walk AS (
    SELECT t.gid AS msg_gid, r.end_id AS current_gid, 1 AS depth
    FROM user_top10 t
    JOIN ldbc_snb."REPLY_OF" r ON r.start_id = t.gid
    WHERE t.mtype = 'C'
    UNION ALL
    SELECT w.msg_gid, r.end_id, w.depth + 1
    FROM reply_walk w
    JOIN ldbc_snb."REPLY_OF" r ON r.start_id = w.current_gid
    WHERE w.depth < 20
  ),
  -- Deepest end_id per msg_gid is the rootPost (Posts have no outgoing REPLY_OF).
  msg_root AS (
    SELECT msg_gid, current_gid AS root_gid
    FROM (
      SELECT msg_gid, current_gid, depth,
             ROW_NUMBER() OVER (PARTITION BY msg_gid ORDER BY depth DESC) AS rn
      FROM reply_walk
    ) ranked
    WHERE rn = 1
  )
SELECT
  ag_catalog.agtype_object_field_text(t.props, 'id')::bigint::ag_catalog.agtype AS messageId,
  COALESCE(
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.props, '"content"'::ag_catalog.agtype]),
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.props, '"imageFile"'::ag_catalog.agtype])
  ) AS messageContent,
  ag_catalog.agtype_object_field_text(t.props, 'creationDate')::bigint::ag_catalog.agtype AS messageCreationDate,
  ag_catalog.agtype_object_field_text(rp.properties, 'id')::bigint::ag_catalog.agtype AS originalPostId,
  ag_catalog.agtype_object_field_text(au.properties, 'id')::bigint::ag_catalog.agtype AS originalPostAuthorId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"firstName"'::ag_catalog.agtype]) AS originalPostAuthorFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"lastName"'::ag_catalog.agtype]) AS originalPostAuthorLastName
FROM user_top10 t
LEFT JOIN msg_root mr ON mr.msg_gid = t.gid
JOIN ldbc_snb."Post" rp  ON rp.id = COALESCE(mr.root_gid, t.gid)
JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = rp.id
JOIN ldbc_snb."Person" au ON au.id = hc.end_id
ORDER BY t.cdate DESC, t.biz_id ASC
LIMIT 10;
