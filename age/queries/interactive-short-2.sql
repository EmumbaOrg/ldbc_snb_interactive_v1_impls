-- LdbcShortQuery2PersonPosts — top-10 recent messages by a person, each with its root-post author.
-- Hybrid: two Cypher calls (Comment arm + Post arm) traverse Person<-HAS_CREATOR-msg.
-- AGE has no polymorphic Message label (AGE-QUIRKS §3): two arms required.
--
-- Root-post lookup (originalPostId / originalPostAuthorId) — PLACEHOLDER:
--   Correct resolution needs a REPLY_OF*0.. variable-length path, which crashes
--   the AGE 1.6 backend (gated on the incoming VLE fix). Pure-SQL recursion over
--   AGE label tables is forbidden (CLAUDE.md). As a placeholder this returns the
--   message's own id as originalPostId and its own creator as originalPostAuthorId.
--   That breaks validation for Comment rows (which have a different root Post), so
--   IS2 shows as incorrect in the validate run — expected, NOT a regression.
--
-- Author name: fetched via GIN-bound scalar LATERAL subquery against Person
-- (permitted by §14 case (b): GIN containment on `properties @> {"id": X}`).

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
  ut.biz_id_bi::ag_catalog.agtype                                               AS messageId,
  ut.content_agt                                                                 AS messageContent,
  ut.cdate_bi::ag_catalog.agtype                                                 AS messageCreationDate,
  -- Placeholder: returns message's own id (not root post id); will use a
  -- REPLY_OF*0.. traversal once the AGE VLE fix lands (see header).
  ut.biz_id_bi::ag_catalog.agtype                                               AS originalPostId,
  $personId::ag_catalog.agtype                                                   AS originalPostAuthorId,
  ag_catalog.text_to_agtype(author.first_name)                                   AS originalPostAuthorFirstName,
  ag_catalog.text_to_agtype(author.last_name)                                    AS originalPostAuthorLastName
FROM user_top10 ut
LEFT JOIN LATERAL (
  SELECT
    ag_catalog.agtype_object_field_text(p.properties, 'firstName') AS first_name,
    ag_catalog.agtype_object_field_text(p.properties, 'lastName')  AS last_name
  FROM ldbc_snb."Person" p
  WHERE p.properties @> (('{"id":' || $personId::text || '}')::ag_catalog.agtype)
  LIMIT 1
) author ON TRUE
ORDER BY ut.cdate_bi DESC, ut.biz_id_bi ASC
LIMIT 10;
