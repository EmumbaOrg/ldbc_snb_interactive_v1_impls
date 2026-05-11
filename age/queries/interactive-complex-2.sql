-- LdbcQuery2 — Top-20 recent messages by direct friends (before maxDate).
-- Hybrid: Cypher call fetches direct friend graphids via KNOWS; SQL filters Comment + Post
-- tables via creator_id denorm column with creationDate <= $maxDate.
-- Two-arm UNION ALL because AGE has no multi-label MATCH (AGE-QUIRKS §3).
-- Denorm used: Comment.creator_id, Post.creator_id (iter-1) + idx_*_creator_creationdate.

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
