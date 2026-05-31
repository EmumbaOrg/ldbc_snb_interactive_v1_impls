-- LdbcQuery10 — FoF with birth-window match, scored by common-interest posts vs total posts.
-- Hybrid: Cypher call computes 2-hop FoF with birth filter (birthMonth/birthDay precomputed
-- per AGE-QUIRKS §1) and direct-friend exclusion; outer SQL computes commonInterestScore
-- using HAS_TAG and HAS_INTEREST AGE edge tables (§14 case (b): GIN-bound scalar subquery).
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11. Fixed-depth MATCH UNION instead of variable-length
-- path per AGE-QUIRKS §4.
--
-- Milestone A 2026-05-30: MessageByCreator retired. Post count now computed inline via
-- Cypher: OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post) with DISTINCT staging
-- per plan requirement (prevents K× path-multiplicity overcount for 2-hop friends).
-- The Cypher block returns (friend graphid, friend biz fields, post graphid per post),
-- then outer SQL GROUP BY friend counts posts and checks HAS_TAG/HAS_INTEREST.
--
-- common_post_count: COUNT(*) FILTER WHERE EXISTS(HAS_TAG ⋈ HAS_INTEREST).
-- HAS_TAG and HAS_INTEREST reads are §14-permitted: graphid-keyed index lookups
-- on non-AGE-managed tables (these are AGE edge tables with graphid PKs). The
-- §14 restriction targets agtype property extraction on full-table scans; indexed
-- graphid JOINs are efficient.

WITH friend_posts AS MATERIALIZED (
  SELECT
    (p_gid::text)::ag_catalog.graphid       AS p_gid,
    (friend_gid::text)::ag_catalog.graphid  AS friend_gid,
    (friend_id::text)::bigint               AS friend_biz_id,
    friend_first_name::text                 AS friend_first_name_t,
    friend_last_name::text                  AS friend_last_name_t,
    friend_gender::text                     AS friend_gender_t,
    city_name::text                         AS city_name_t,
    NULLIF(post_gid::text, '')::ag_catalog.graphid AS post_gid
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH DISTINCT p, friend
    WHERE ((friend.birthMonth = $month AND friend.birthDay >= 21)
        OR (friend.birthMonth = ($month % 12) + 1 AND friend.birthDay < 22))
    OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
    WITH p, friend, direct WHERE direct IS NULL
    MATCH (friend)-[:IS_LOCATED_IN]->(city:City)
    WITH DISTINCT p, friend, city
    OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
    RETURN id(p), id(friend), friend.id, friend.firstName, friend.lastName,
           friend.gender, city.name, id(post)
  $$) AS (p_gid agtype, friend_gid agtype, friend_id agtype,
          friend_first_name agtype, friend_last_name agtype,
          friend_gender agtype, city_name agtype, post_gid agtype)
),
per_friend AS (
  SELECT
    p_gid,
    friend_gid,
    friend_biz_id,
    friend_first_name_t,
    friend_last_name_t,
    friend_gender_t,
    city_name_t,
    COUNT(post_gid)                                       AS total_post_count,
    COUNT(post_gid) FILTER (WHERE EXISTS (
      SELECT 1 FROM ldbc_snb."HAS_TAG" ht
      JOIN ldbc_snb."HAS_INTEREST" hi
        ON hi.start_id = fp.p_gid AND hi.end_id = ht.end_id
      WHERE ht.start_id = fp.post_gid
    ))                                                    AS common_post_count
  FROM friend_posts fp
  GROUP BY p_gid, friend_gid, friend_biz_id,
           friend_first_name_t, friend_last_name_t,
           friend_gender_t, city_name_t
)
SELECT
  friend_biz_id::ag_catalog.agtype                                            AS personId,
  ('"' || friend_first_name_t || '"')::ag_catalog.agtype                      AS personFirstName,
  ('"' || friend_last_name_t  || '"')::ag_catalog.agtype                      AS personLastName,
  (2 * common_post_count - total_post_count)::ag_catalog.agtype               AS commonInterestScore,
  ('"' || friend_gender_t || '"')::ag_catalog.agtype                          AS personGender,
  ('"' || city_name_t     || '"')::ag_catalog.agtype                          AS personCityName
FROM per_friend
ORDER BY (2 * common_post_count - total_post_count) DESC, friend_biz_id ASC
LIMIT 10;
