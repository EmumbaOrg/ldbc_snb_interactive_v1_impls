-- LdbcQuery10 — FoF with birth-window match, scored by common-interest posts vs total posts.
-- Hybrid: Cypher call computes 2-hop FoF with birth filter (birthMonth/birthDay precomputed
-- per AGE-QUIRKS §1) and direct-friend exclusion; SQL computes commonInterestScore using
-- PersonPostCount side table + Post.creator_id denorm + HAS_TAG/HAS_INTEREST indexed JOIN.
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11. Fixed-depth MATCH UNION instead of variable-length
-- path per AGE-QUIRKS §4.
-- Denorm used: Post.creator_id (iter-1), PersonPostCount(person_id) (iter-2 aggregate).

WITH surviving_friends AS (
  SELECT
    (p_gid::text)::ag_catalog.graphid       AS p_gid,
    (friend_gid::text)::ag_catalog.graphid  AS friend_gid,
    (friend_id::text::bigint)               AS friend_biz_id,
    friend_first_name::text                 AS friend_first_name_t,
    friend_last_name::text                  AS friend_last_name_t,
    friend_gender::text                     AS friend_gender_t,
    city_name::text                         AS city_name_t
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH DISTINCT p, friend
    WHERE ((friend.birthMonth = $month AND friend.birthDay >= 21)
        OR (friend.birthMonth = ($month % 12) + 1 AND friend.birthDay < 22))
    OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
    WITH p, friend, direct WHERE direct IS NULL
    MATCH (friend)-[:IS_LOCATED_IN]->(city:City)
    RETURN id(p), id(friend), friend.id, friend.firstName, friend.lastName,
           friend.gender, city.name
  $$) AS (p_gid agtype, friend_gid agtype, friend_id agtype,
          friend_first_name agtype, friend_last_name agtype,
          friend_gender agtype, city_name agtype)
)
SELECT
  friend_biz_id::ag_catalog.agtype                                 AS personId,
  ('"' || friend_first_name_t || '"')::ag_catalog.agtype           AS personFirstName,
  ('"' || friend_last_name_t  || '"')::ag_catalog.agtype           AS personLastName,
  ((2 * common_post_count - COALESCE(ppc.post_count, 0)))::ag_catalog.agtype AS commonInterestScore,
  ('"' || friend_gender_t || '"')::ag_catalog.agtype               AS personGender,
  ('"' || city_name_t     || '"')::ag_catalog.agtype               AS personCityName
FROM surviving_friends sf
LEFT JOIN ldbc_snb."PersonPostCount" ppc ON ppc.person_id = sf.friend_gid
LEFT JOIN LATERAL (
  SELECT COUNT(DISTINCT post.id) AS common_post_count
  FROM ldbc_snb."Post" post
  WHERE post.creator_id = sf.friend_gid
    AND EXISTS (
      SELECT 1 FROM ldbc_snb."HAS_TAG" ht
      JOIN ldbc_snb."HAS_INTEREST" hi
        ON hi.start_id = sf.p_gid AND hi.end_id = ht.end_id
      WHERE ht.start_id = post.id
    )
) cp ON TRUE
ORDER BY (2 * common_post_count - COALESCE(ppc.post_count, 0)) DESC, friend_biz_id ASC
LIMIT 10;
