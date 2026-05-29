-- LdbcQuery10 — FoF with birth-window match, scored by common-interest posts vs total posts.
-- Hybrid: Cypher call computes 2-hop FoF with birth filter (birthMonth/birthDay precomputed
-- per AGE-QUIRKS §1) and direct-friend exclusion; SQL computes commonInterestScore using
-- the MessageByCreator side table (no AGE label-table reads in outer SQL).
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11. Fixed-depth MATCH UNION instead of variable-length
-- path per AGE-QUIRKS §4.
--
-- Direct-friend exclusion: `NOT EXISTS { MATCH (p)-[:KNOWS]->(friend) }` instead of the
-- OPTIONAL MATCH (direct) + WHERE direct IS NULL pattern. Measured 2026-05-15 SF3: ~2×
-- faster (131ms vs 259ms) for the Cypher block alone with byte-identical output.
--
-- Common- and total-post-count via MessageByCreator: a single LATERAL scans
-- MessageByCreator by (creator_business_id = friend, is_post = true) using the
-- composite index. total_post_count = COUNT(*) over that range; common_post_count
-- = COUNT(*) FILTER on a per-post EXISTS tag-intersection against HAS_TAG /
-- HAS_INTEREST. The HAS_TAG join uses MessageByCreator.message_id (graphid)
-- as the start_id — this column was added 2026-05-15 specifically so IC10
-- doesn't have to read the AGE Post label table for the post graphid.
--
-- PersonPostCount retired Phase B 2026-05-29: total post count was previously a
-- LEFT JOIN against the PPC counter cache. It is now COUNT(*) over the same MBC
-- range already scanned for common_post_count — one index range scan per friend,
-- no separate count probe. message_business_id is unique in MBC, so COUNT(*)
-- equals the prior COUNT(DISTINCT message_business_id).
--
-- Post.creator_id retired 2026-05-15: the prior `WHERE post.creator_id = sf.friend_gid`
-- filter is replaced by `m.creator_business_id = sf.friend_biz_id AND m.is_post`.
-- IU6's UPDATE Post SET creator_id is also retired. idx_post_creator_id dropped
-- by migration `2026-05-15-tier3b-drop-post-creator-id-usage.sql`.
--
-- Denorm used: MessageByCreator(creator_business_id, message_id, is_post).
-- HAS_TAG and HAS_INTEREST are still read from outer SQL — those AGE-edge §14 violations
-- are tracked as a separate cleanup (would need PostTags + PersonInterests side tables;
-- ~20M rows at SF1000 storage cost).

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
  (2 * cp.common_post_count - cp.total_post_count)::ag_catalog.agtype AS commonInterestScore,
  ('"' || friend_gender_t || '"')::ag_catalog.agtype               AS personGender,
  ('"' || city_name_t     || '"')::ag_catalog.agtype               AS personCityName
FROM surviving_friends sf
LEFT JOIN LATERAL (
  SELECT
    COUNT(*) FILTER (WHERE per_post.has_common_tag) AS common_post_count,
    COUNT(*)                                        AS total_post_count
  FROM (
    SELECT EXISTS (
             SELECT 1 FROM ldbc_snb."HAS_TAG" ht
             JOIN ldbc_snb."HAS_INTEREST" hi
               ON hi.start_id = sf.p_gid AND hi.end_id = ht.end_id
             WHERE ht.start_id = m.message_id
           ) AS has_common_tag
    FROM ldbc_snb."MessageByCreator" m
    WHERE m.creator_business_id = sf.friend_biz_id
      AND m.is_post = true
  ) per_post
) cp ON TRUE
ORDER BY (2 * cp.common_post_count - cp.total_post_count) DESC, friend_biz_id ASC
LIMIT 10;
