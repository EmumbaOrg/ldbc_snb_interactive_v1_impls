-- LdbcQuery8 — Recent replies (V2 — denormalised; mirrors postgres ref)
--
-- Postgres reference impl pattern:
--   select p1.m_creatorid, p_firstname, p_lastname, p1.m_creationdate, p1.m_messageid, p1.m_content
--     from message p1, message p2, person
--    where p1.m_c_replyof = p2.m_messageid
--      and p2.m_creatorid = :personId
--      and p_personid = p1.m_creatorid
--    order by p1.m_creationdate desc, p1.m_messageid asc limit 20;
--
-- Uses `m_c_replyof` (REPLY_OF target denormalised onto Comment) and
-- `m_creatorid` (HAS_CREATOR denormalised). Direct indexed JOIN, no edge
-- traversal. We mirror via Comment.reply_of_id and Comment.creator_id +
-- Comment.reply_of_id index, Post.creator_id index.
--
-- Hot path: find user's messages (Comment + Post), find Comments whose
-- reply_of_id is in that set, JOIN to author Person.

WITH user_gid AS (
  SELECT id FROM ldbc_snb."Person"
  WHERE CAST(ag_catalog.agtype_object_field_text(properties, 'id') AS bigint) = $personId
),
user_msg_ids AS (
  SELECT id AS msg_id FROM ldbc_snb."Comment" m
  WHERE m.creator_id = (SELECT id FROM user_gid)
  UNION ALL
  SELECT id FROM ldbc_snb."Post" m
  WHERE m.creator_id = (SELECT id FROM user_gid)
)
SELECT
  ag_catalog.agtype_object_field_text(au.properties, 'id')::bigint::ag_catalog.agtype                AS personId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"firstName"'::ag_catalog.agtype])  AS personFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[au.properties, '"lastName"'::ag_catalog.agtype])   AS personLastName,
  ag_catalog.agtype_object_field_text(reply.properties, 'creationDate')::bigint::ag_catalog.agtype   AS commentCreationDate,
  ag_catalog.agtype_object_field_text(reply.properties, 'id')::bigint::ag_catalog.agtype             AS commentId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[reply.properties, '"content"'::ag_catalog.agtype]) AS commentContent
FROM ldbc_snb."Comment" reply
JOIN user_msg_ids ums ON ums.msg_id = reply.reply_of_id
JOIN ldbc_snb."Person" au ON au.id = reply.creator_id
ORDER BY (ag_catalog.agtype_object_field_text(reply.properties, 'creationDate')::bigint) DESC,
         (ag_catalog.agtype_object_field_text(reply.properties, 'id')::bigint) ASC
LIMIT 20;
