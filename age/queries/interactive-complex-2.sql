-- LdbcQuery2 — Recent messages by friends (V2 — denormalised; mirrors postgres ref)
--
-- Postgres reference impl pattern:
--   select p_personid, ..., m_messageid, COALESCE(m_ps_imagefile, m_content), m_creationdate
--   from person, message, knows
--   where p_personid = m_creatorid
--     and m_creationdate <= :maxDate
--     and k_person1id = :personId
--     and k_person2id = p_personid
--   order by m_creationdate desc, m_messageid asc limit 20;
--
-- The reference uses `m_creatorid` (HAS_CREATOR denormalised onto Comment+Post).
-- We mirror this via Comment.creator_id and Post.creator_id columns +
-- composite indexes idx_*_creator_creationdate.
--
-- The friend set comes from Cypher (KNOWS is N:N edge → kept as edge table,
-- same as postgres ref's `knows`). Then SQL JOIN against Comment + Post
-- via creator_id to pick top-20 messages.
--
-- Two-arm UNION ALL because Comment and Post are separate AGE labels (the
-- postgres ref unions them into one `message` table at load time; we keep
-- them separate to preserve AGE vertex-label semantics elsewhere).

SELECT
  ag_catalog.agtype_object_field_text(au.properties, 'id')::bigint::ag_catalog.agtype                       AS personId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"firstName"'::ag_catalog.agtype])         AS personFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"lastName"'::ag_catalog.agtype])          AS personLastName,
  ag_catalog.agtype_object_field_text(msg_props, 'id')::bigint::ag_catalog.agtype                            AS postOrCommentId,
  COALESCE(
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[msg_props, '"content"'::ag_catalog.agtype]),
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[msg_props, '"imageFile"'::ag_catalog.agtype])
  )                                                                                                          AS postOrCommentContent,
  ag_catalog.agtype_object_field_text(msg_props, 'creationDate')::bigint::ag_catalog.agtype                  AS postOrCommentCreationDate
FROM (
  SELECT m.creator_id AS author_id, m.properties AS msg_props,
         CAST(ag_catalog.agtype_object_field_text(m.properties, 'creationDate') AS bigint) AS cdate,
         CAST(ag_catalog.agtype_object_field_text(m.properties, 'id') AS bigint)           AS biz_id
  FROM ldbc_snb."Comment" m
  WHERE m.creator_id IN (
    SELECT (fg::text)::ag_catalog.graphid
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
      RETURN id(friend)
    $$) AS x(fg agtype)
  )
  AND CAST(ag_catalog.agtype_object_field_text(m.properties, 'creationDate') AS bigint) <= $maxDate
  UNION ALL
  SELECT m.creator_id, m.properties,
         CAST(ag_catalog.agtype_object_field_text(m.properties, 'creationDate') AS bigint),
         CAST(ag_catalog.agtype_object_field_text(m.properties, 'id') AS bigint)
  FROM ldbc_snb."Post" m
  WHERE m.creator_id IN (
    SELECT (fg::text)::ag_catalog.graphid
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
      RETURN id(friend)
    $$) AS x(fg agtype)
  )
  AND CAST(ag_catalog.agtype_object_field_text(m.properties, 'creationDate') AS bigint) <= $maxDate
) all_msgs
JOIN ldbc_snb."Person" au ON au.id = all_msgs.author_id
ORDER BY all_msgs.cdate DESC, all_msgs.biz_id ASC
LIMIT 20;
