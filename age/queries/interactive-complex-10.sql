-- LdbcQuery10 — FoF with birth-window match, scored by common-interest posts vs total posts.
-- Hybrid: Cypher handles all graph traversal AND the tag-overlap scoring.
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11. Fixed-depth MATCH UNION instead of variable-length
-- path per AGE-QUIRKS §4.
--
-- Tag-overlap scoring is fully inside Cypher using EXISTS {} subpattern:
--   count(DISTINCT CASE WHEN EXISTS { MATCH (post)-[:HAS_TAG]->(:Tag)<-[:HAS_INTEREST]-(p) }
--         THEN post END)
-- Both EXISTS{} and count(DISTINCT CASE WHEN … END) are AGE-1.6 supported per CLAUDE.md.
-- Outer SQL is a thin cast/format wrapper only — no JOIN or aggregate against any AGE label table.

SELECT
  (friend_id::text)::bigint::ag_catalog.agtype                                  AS personId,
  ('"' || (friend_first_name::text) || '"')::ag_catalog.agtype                 AS personFirstName,
  ('"' || (friend_last_name::text)  || '"')::ag_catalog.agtype                 AS personLastName,
  (common_interest_score::text)::bigint::ag_catalog.agtype                      AS commonInterestScore,
  ('"' || (friend_gender::text)     || '"')::ag_catalog.agtype                 AS personGender,
  ('"' || (city_name::text)         || '"')::ag_catalog.agtype                 AS personCityName
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
  WITH p, friend, city,
       count(DISTINCT post) AS total,
       count(DISTINCT CASE
         WHEN EXISTS { MATCH (post)-[:HAS_TAG]->(:Tag)<-[:HAS_INTEREST]-(p) }
         THEN post END) AS common
  RETURN friend.id, friend.firstName, friend.lastName,
         2*common - total AS commonInterestScore,
         friend.gender, city.name
$$) AS (friend_id agtype, friend_first_name agtype, friend_last_name agtype,
        common_interest_score agtype, friend_gender agtype, city_name agtype)
-- ORDER BY + LIMIT stay in outer SQL: AGE 1.6 rejects ORDER BY on a Cypher RETURN
-- alias ("could not find rte"). Sort key is numeric (score, then id) — no COLLATE.
ORDER BY (common_interest_score::text)::bigint DESC, (friend_id::text)::bigint ASC
LIMIT 10;
