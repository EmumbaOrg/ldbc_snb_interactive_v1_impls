-- LdbcShortQuery2PersonPosts — top-10 recent messages by a person, each with its root-post author.
-- Hybrid: two Cypher calls (Comment branch + Post branch) traverse Person<-HAS_CREATOR-msg
-- (AGE-QUIRKS §3 forbids multi-label MATCH so the Comment+Post split is required).
-- Phase A 2026-05-28: PersonSide retired; author firstName/lastName fetched via GIN-bound
-- scalar LATERAL subquery against Person (permitted by §14 case (b)).
-- CommentRootPost and MessageByCreator remain (Phases D/E retire those).

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
  ut.biz_id_bi::ag_catalog.agtype                                                AS messageId,
  ut.content_agt                                                                  AS messageContent,
  ut.cdate_bi::ag_catalog.agtype                                                  AS messageCreationDate,
  COALESCE(crp.root_post_business_id, ut.biz_id_bi)::ag_catalog.agtype            AS originalPostId,
  rp.creator_business_id::ag_catalog.agtype                                       AS originalPostAuthorId,
  ag_catalog.text_to_agtype(author.first_name)                                    AS originalPostAuthorFirstName,
  ag_catalog.text_to_agtype(author.last_name)                                     AS originalPostAuthorLastName
FROM user_top10 ut
LEFT JOIN ldbc_snb."CommentRootPost" crp
       ON ut.mtype = 'C' AND crp.comment_business_id = ut.biz_id_bi
JOIN ldbc_snb."MessageByCreator" rp
       ON rp.message_business_id = COALESCE(crp.root_post_business_id, ut.biz_id_bi)
      AND rp.is_post
LEFT JOIN LATERAL (
  SELECT
    ag_catalog.agtype_object_field_text(p.properties, 'firstName') AS first_name,
    ag_catalog.agtype_object_field_text(p.properties, 'lastName')  AS last_name
  FROM ldbc_snb."Person" p
  WHERE p.properties @> (('{"id":' || rp.creator_business_id::text || '}')::ag_catalog.agtype)
  LIMIT 1
) author ON TRUE
ORDER BY ut.cdate_bi DESC, ut.biz_id_bi ASC
LIMIT 10;
