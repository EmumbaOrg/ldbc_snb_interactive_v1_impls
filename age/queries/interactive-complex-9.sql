-- LdbcQuery9 — Top-20 recent messages (before maxDate) by friends and FoF.
-- Hybrid: one Cypher call builds the 1+2-hop friend graphid set via fixed-depth MATCH UNION
-- (no variable-length path per AGE-QUIRKS §4); SQL walks idx_comment_date_id / idx_post_date_id
-- backwards and stops via Nested Loop Semi Join once 20 friend-authored rows accumulate.
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11 — undirected forces a KNOWS seq scan at scale.
-- Typed-relationship pattern negation `NOT (p)-[:KNOWS]-(f)` is rejected by the AGE parser
-- (AGE-QUIRKS §10); UNION deduplication is semantically equivalent and used here.
-- Excluded from age_parameterized_queries: the Cypher block uses $personId while outer SQL
-- uses $maxDate — they cannot share a single agtype JSON bind.
-- TODO: if at SF1000+ the date-DESC walk runs long before hitting 20 friend rows, push
--       creationDate onto HAS_CREATOR edge and add composite idx_hascreator_end_creationdate.

WITH all_friends AS (
  SELECT (g::text)::ag_catalog.graphid AS friend_id
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(f1:Person)
    WHERE f1.id <> $personId
    RETURN id(f1) AS friend_gid
    UNION
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(f2:Person)
    WHERE f2.id <> $personId
    RETURN id(f2) AS friend_gid
  $$) AS x(g agtype)
),
top_comments AS (
  -- Walk idx_comment_date_id from `< $maxDate` backwards; planner stops
  -- the index walk as soon as the Nested Loop Semi Join accumulates 20 rows
  -- whose creator is in all_friends.
  SELECT msg.id        AS msg_gid,
         msg.properties AS msg_props,
         hc.end_id     AS author_gid,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) AS cdate,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint)           AS msg_id_biz
  FROM ldbc_snb."Comment" msg
  JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = msg.id
  WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) < $maxDate
    AND hc.end_id IN (SELECT friend_id FROM all_friends)
  ORDER BY 4 DESC, 5 ASC
  LIMIT 20
),
top_posts AS (
  SELECT msg.id        AS msg_gid,
         msg.properties AS msg_props,
         hc.end_id     AS author_gid,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) AS cdate,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint)           AS msg_id_biz
  FROM ldbc_snb."Post" msg
  JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = msg.id
  WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) < $maxDate
    AND hc.end_id IN (SELECT friend_id FROM all_friends)
  ORDER BY 4 DESC, 5 ASC
  LIMIT 20
)
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"id"'::ag_catalog.agtype])         AS personId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"firstName"'::ag_catalog.agtype])  AS personFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"lastName"'::ag_catalog.agtype])   AS personLastName,
  t.msg_id_biz::ag_catalog.agtype                                                                      AS messageId,
  COALESCE(
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.msg_props, '"content"'::ag_catalog.agtype]),
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.msg_props, '"imageFile"'::ag_catalog.agtype])
  )                                                                                                    AS messageContent,
  t.cdate::ag_catalog.agtype                                                                           AS messageCreationDate
FROM (SELECT * FROM top_comments UNION ALL SELECT * FROM top_posts) t
JOIN ldbc_snb."Person" per ON per.id = t.author_gid
ORDER BY t.cdate DESC, t.msg_id_biz ASC
LIMIT 20;
