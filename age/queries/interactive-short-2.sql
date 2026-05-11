-- LdbcShortQuery2PersonPosts — top-10 recent messages by a person, each with its root-post author.
-- Hybrid: two Cypher calls (Comment branch, Post branch) fetch the top-10 messages via
-- HAS_CREATOR (AGE-QUIRKS §3: no multi-label MATCH); SQL recursive CTE walks REPLY_OF to
-- find each comment's root Post. Variable-length REPLY_OF in Cypher hits a path-enumeration
-- pathology at scale (AGE-QUIRKS §4, §9) — SQL CTE is the structural fix.
-- Denorm used: none (REPLY_OF chain walk uses edge table directly).
-- mtype discriminator ('C'/'P') is plain text to avoid agtype quote noise.

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
