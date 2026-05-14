-- LdbcQuery10 — FoF with birth-window match, scored by common-interest posts vs total posts.
-- V7: Two-call structure splits FoF walk from interest scoring.
-- First call: directed 2-hop KNOWS walk, birthday window, direct-friend exclusion, city lookup.
-- Second call: traverses p's interests ONCE per query (not once per friend), changing scaling
-- from O(friends × posts_per_friend) to O(interests × posts_per_tag).
-- SQL outer layer joins the two Cypher results and the PersonPostCount side table only.
-- Directed -[:KNOWS]-> per AGE-QUIRKS §11. Fixed-depth 2-hop per AGE-QUIRKS §4.
-- count(DISTINCT post) aggregated in WITH before RETURN per AGE-QUIRKS §5.
-- Indexes: gin_person (seed), idx_knows_start (FoF), idx_islocatedin_start (city),
--          idx_hasinterest_start (p->tags), idx_hastag_end (tag<-posts),
--          idx_hascreator_start (post->creator), PersonPostCount PK.

WITH surviving_friends AS (
  SELECT
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
    WITH DISTINCT friend, direct WHERE direct IS NULL
    MATCH (friend)-[:IS_LOCATED_IN]->(city:City)
    RETURN id(friend), friend.id, friend.firstName, friend.lastName,
           friend.gender, city.name
  $$) AS (friend_gid agtype, friend_id agtype,
          friend_first_name agtype, friend_last_name agtype,
          friend_gender agtype, city_name agtype)
),
interest_post_counts AS (
  SELECT
    (creator_gid::text)::ag_catalog.graphid  AS creator_gid,
    (score::text)::bigint                    AS common_post_count
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:HAS_INTEREST]->(tag:Tag)<-[:HAS_TAG]-(post:Post)-[:HAS_CREATOR]->(creator:Person)
    WITH creator, count(DISTINCT post) AS score
    RETURN id(creator), score
  $$) AS (creator_gid agtype, score agtype)
)
SELECT
  sf.friend_biz_id::ag_catalog.agtype                                                         AS personId,
  ('"' || sf.friend_first_name_t || '"')::ag_catalog.agtype                                   AS personFirstName,
  ('"' || sf.friend_last_name_t  || '"')::ag_catalog.agtype                                   AS personLastName,
  ((2 * COALESCE(ipc.common_post_count, 0) - COALESCE(ppc.post_count, 0)))::ag_catalog.agtype AS commonInterestScore,
  ('"' || sf.friend_gender_t     || '"')::ag_catalog.agtype                                   AS personGender,
  ('"' || sf.city_name_t         || '"')::ag_catalog.agtype                                   AS personCityName
FROM surviving_friends sf
LEFT JOIN interest_post_counts ipc ON ipc.creator_gid = sf.friend_gid
LEFT JOIN ldbc_snb."PersonPostCount" ppc ON ppc.person_id = sf.friend_gid
ORDER BY (2 * COALESCE(ipc.common_post_count, 0) - COALESCE(ppc.post_count, 0)) DESC,
         sf.friend_biz_id ASC
LIMIT 10;
