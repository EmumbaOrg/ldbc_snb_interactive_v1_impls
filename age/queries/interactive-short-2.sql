-- LdbcShortQuery2PersonPosts (V2 — hybrid: Cypher top-10 + SQL chain walk)
--
-- Classification: Genuine hybrid — Cypher does the substantive graph fetch
-- (user's top-10 messages via HAS_CREATOR traversal); SQL retains the
-- recursive REPLY_OF chain walk for structural reasons.
--
-- Cypher top-10 fetch (V2):
--   Two Cypher calls (Comment branch, Post branch), each with a final
--   RETURN ... ORDER BY ... LIMIT 10. This is safe — the plan note
--   "mid-query WITH ... LIMIT is poisoned" applies only when the LIMIT
--   is followed by another MATCH inside the same Cypher block. Final
--   RETURN ORDER BY LIMIT is fine and correctly uses idx_hascreator_end.
--   The two branches are UNION ALL'd in SQL and the outer ORDER BY / LIMIT 10
--   picks the top-10 across both label tables.
--
-- SQL REPLY_OF chain walk (retained from iter-3):
--   AGE 1.6's variable-length path pathology + label-explosion on untyped
--   intermediates make a pure-Cypher REPLY_OF walk structurally unfit at
--   SF100+ (see AGE-QUIRKS §4, §9). Measured ceiling: ~250 ms at SF0.1
--   with linear growth in Post table size. Structural — keep SQL recursive
--   CTE. See iter-3 banner for full rationale.
--
-- Column shape for AgeConverter:
--   (1) messageId          bigint agtype   — toLong
--   (2) messageContent     text agtype     — toStr
--   (3) messageCreationDate bigint agtype  — toLong
--   (4) originalPostId     bigint agtype   — toLong
--   (5) originalPostAuthorId bigint agtype — toLong
--   (6) originalPostAuthorFirstName text agtype — toStr
--   (7) originalPostAuthorLastName  text agtype — toStr
--
-- mtype discriminator uses plain text ('C'/'P') — no agtype quote noise.
-- graphid cast: (gid::text)::ag_catalog.graphid — id(msg) returns agtype integer.

WITH RECURSIVE
  user_top10 AS MATERIALIZED (
    SELECT *
    FROM (
      SELECT
        (gid::text)::ag_catalog.graphid AS gid,
        'C'::text AS mtype,
        biz_id::text::bigint AS biz_id_bi,
        cdate::text::bigint AS cdate_bi,
        content AS content_agtype
      FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)
        RETURN id(msg), msg.id, msg.creationDate,
               coalesce(msg.content, msg.imageFile)
        ORDER BY msg.creationDate DESC, msg.id ASC
        LIMIT 10
      $$) AS x(gid agtype, biz_id agtype, cdate agtype, content agtype)
      UNION ALL
      SELECT
        (gid::text)::ag_catalog.graphid AS gid,
        'P'::text AS mtype,
        biz_id::text::bigint AS biz_id_bi,
        cdate::text::bigint AS cdate_bi,
        content AS content_agtype
      FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)
        RETURN id(msg), msg.id, msg.creationDate,
               coalesce(msg.content, msg.imageFile)
        ORDER BY msg.creationDate DESC, msg.id ASC
        LIMIT 10
      $$) AS y(gid agtype, biz_id agtype, cdate agtype, content agtype)
    ) merged
    ORDER BY cdate_bi DESC, biz_id_bi ASC
    LIMIT 10
  ),
  -- Walk REPLY_OF up to depth 20 (LDBC reply chains are bounded ~8 across all SFs).
  -- Each step is one indexed lookup on idx_replyof_start.
  -- Posts have no outgoing REPLY_OF edges, so the walk terminates naturally at
  -- the rootPost — deepest end_id IS the rootPost. No join back to Post table.
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
  -- Deepest end_id per msg_gid is the rootPost.
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
  t.biz_id_bi::ag_catalog.agtype                                                                     AS messageId,
  t.content_agtype                                                                                   AS messageContent,
  t.cdate_bi::ag_catalog.agtype                                                                      AS messageCreationDate,
  ag_catalog.agtype_object_field_text(rp.properties, 'id')::bigint::ag_catalog.agtype               AS originalPostId,
  ag_catalog.agtype_object_field_text(au.properties, 'id')::bigint::ag_catalog.agtype               AS originalPostAuthorId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"firstName"'::ag_catalog.agtype]) AS originalPostAuthorFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"lastName"'::ag_catalog.agtype])  AS originalPostAuthorLastName
FROM user_top10 t
LEFT JOIN msg_root mr ON mr.msg_gid = t.gid
JOIN ldbc_snb."Post" rp  ON rp.id = COALESCE(mr.root_gid, t.gid)
JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = rp.id
JOIN ldbc_snb."Person" au ON au.id = hc.end_id
ORDER BY t.cdate_bi DESC, t.biz_id_bi ASC
LIMIT 10;
