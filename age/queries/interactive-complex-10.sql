-- LdbcQuery10 — Similar persons (V5 — hybrid using PersonPostCount + denorm)
--
-- V4 used Cypher walks for everything: 2-hop KNOWS + DISTINCT + birth filter +
-- direct exclusion + city lookup + per-friend post enumeration + per-post
-- tag-interest check. SF3: 23.8 s → 13.2 s after collect+UNWIND barrier.
-- The per-friend post enumeration (~108 posts/friend at SF3 → ~10 800 at
-- SF1000) is the dominant remaining cost.
--
-- V5 keeps Cypher for the friend tree (KNOWS is N:N — same as postgres ref's
-- `knows` join table) but moves all post-counting to SQL using the iter-2
-- aggregate side tables + iter-1 column denorms:
--   - `PersonPostCount.post_count` replaces postCount enumeration with a
--     single index lookup per friend.
--   - `Post.creator_id` (denorm) + `HAS_TAG` + composite
--     `idx_hasinterest_start_end(start_id, end_id)` give the common-interest
--     post count via a 3-table indexed JOIN — no Cypher OPTIONAL MATCH walk.
--
-- Estimated SF3 mean: 13.2 s → ~1.5 s. SF1000: ~50 s → ~6 s.

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
