-- LdbcQuery3 — Friends and FoF with messages in two countries (xCount/yCount/xyCount).
-- Hybrid: two Cypher arms (Comment + Post — AGE 1.6 has no multi-label MATCH, AGE-QUIRKS §3).
-- Each arm drives from the COUNTRY side (`idx_country_name` → `idx_islocatedin_end`), pulls
-- in-window messages, then EXISTS-checks the message creator is 1-hop or 2-hop friend of $personId.
--
-- Key shape: the friend-set is NOT pre-computed; instead, each candidate message-creator is
-- checked via `EXISTS { (p)-[:KNOWS]->(friend) }` (1-hop) OR `EXISTS { (p)-[:KNOWS]->(:Person)-[:KNOWS]->(friend) }` (2-hop).
-- Country-side has small cardinality (a few thousand messages per (country, date-window) pair),
-- so the per-message EXISTS probe is cheap and beats pre-computing the 1+2-hop friend set
-- (which for SF3 typically has 4-5k friends, requiring a 3-hop country-filter walk per friend).
-- Measured 2026-05-15 SF3: 9× mean speedup vs prior pre-compute shape across 5 sample params,
-- with byte-identical output.
--
-- AGE 1.6 constructs used (per AGENTS.md §"AGE 1.6 Cypher Constructs"):
--   - `EXISTS { pattern }` subquery — both nested 1-hop and 2-hop variants
--   - directed `-[:KNOWS]->` per AGE-QUIRKS §11 (IU8 stores bidirectionally)
--
-- HAS_CREATOR direction: edges are stored (Message)-[:HAS_CREATOR]->(Person), so the
-- correct pattern is `(msg)-[:HAS_CREATOR]->(friend)`. A reversed `<-` form returns 0 rows
-- silently (AGENTS.md "How to Review a Query" §2 — edge directions).
--
-- IC3 is excluded from age_parameterized_queries because outer SQL references country names.
-- AGE-QUIRKS §14: outer-SQL `WHERE countryName::text = $countryXName` is correct as long as
-- `$countryXName` is a single-quoted SQL string literal (`convertString` from Java handler).

SELECT friendId, friendFirstName, friendLastName,
       SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END)::int AS xCount,
       SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END)::int AS yCount,
       COUNT(*)::int AS xyCount
FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})
    MATCH (country:Country)<-[:IS_LOCATED_IN]-(msg:Comment)-[:HAS_CREATOR]->(friend:Person)
    WHERE country.name IN [$countryXName, $countryYName]
      AND msg.creationDate >= $startDate AND msg.creationDate < $endDate
      AND friend.id <> $personId
      AND ( EXISTS { MATCH (p)-[:KNOWS]->(friend) }
         OR EXISTS { MATCH (p)-[:KNOWS]->(:Person)-[:KNOWS]->(friend) } )
    MATCH (friend)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(fc:Country)
    WHERE fc.name <> $countryXName AND fc.name <> $countryYName
    RETURN friend.id, friend.firstName, friend.lastName, country.name
  $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})
    MATCH (country:Country)<-[:IS_LOCATED_IN]-(msg:Post)-[:HAS_CREATOR]->(friend:Person)
    WHERE country.name IN [$countryXName, $countryYName]
      AND msg.creationDate >= $startDate AND msg.creationDate < $endDate
      AND friend.id <> $personId
      AND ( EXISTS { MATCH (p)-[:KNOWS]->(friend) }
         OR EXISTS { MATCH (p)-[:KNOWS]->(:Person)-[:KNOWS]->(friend) } )
    MATCH (friend)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(fc:Country)
    WHERE fc.name <> $countryXName AND fc.name <> $countryYName
    RETURN friend.id, friend.firstName, friend.lastName, country.name
  $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
) msgs
GROUP BY friendId, friendFirstName, friendLastName
HAVING SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END) > 0
ORDER BY xyCount DESC, friendId ASC
LIMIT 20;
