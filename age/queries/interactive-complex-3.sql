-- LdbcQuery3 — Friends and FoF with messages in two countries (xCount/yCount/xyCount).
-- Hybrid: two Cypher calls (Comment arm, Post arm) each compute the full 1+2-hop friend
-- set once via collect(DISTINCT id(…)) graphid lists, then re-MATCH friends, drive the
-- message scan from the country side (idx_islocatedin_end), and apply date post-filter.
-- SQL does GROUP BY / HAVING / ORDER / LIMIT. Two arms required because AGE has no
-- label-OR predicate (AGE-QUIRKS §3). Friend-set uses graphid collect, not full vertex
-- objects, to avoid Sort+GroupAggregate on ~500-byte agtype blobs at scale (AGE-QUIRKS §6).
-- IC3 is excluded from age_parameterized_queries because outer SQL references country names.
--
-- HAS_CREATOR direction: edges are stored (Message)-[:HAS_CREATOR]->(Person), so the
-- correct pattern is `(msg)-[:HAS_CREATOR]->(friend)`. A reversed `<-` form returns 0
-- rows silently (AGENTS.md "How to Review a Query" §2 — edge directions).
--
-- TODO: denorm Person.country_name to collapse friend-country anti-join from 2-hop to a
--       property check (saves ~10-30 ms per call at SF1000+).

SELECT friendId, friendFirstName, friendLastName,
       SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END)::int AS xCount,
       SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END)::int AS yCount,
       COUNT(*)::int AS xyCount
FROM (
  SELECT * FROM cypher('$graphName', $$
    // (1) Compute direct + 2-hop friend graphids in a single pass.
    MATCH (p:Person {id: $personId})-[:KNOWS]->(d1:Person)
    WHERE d1.id <> $personId
    WITH p, collect(DISTINCT id(d1)) AS direct_ids
    UNWIND CASE WHEN size(direct_ids) = 0 THEN [null] ELSE direct_ids END AS did
    OPTIONAL MATCH (d:Person)-[:KNOWS]->(d2:Person)
      WHERE id(d) = did AND d2 <> p AND NOT id(d2) IN direct_ids
    WITH p, direct_ids, collect(DISTINCT id(d2)) AS foaf_ids
    WITH p, direct_ids + foaf_ids AS all_friend_ids
    // (2) Re-MATCH each friend by graphid (cheap idx_person_graphid lookup).
    UNWIND all_friend_ids AS fid
    MATCH (friend:Person) WHERE id(friend) = fid
    // (3) Filter out friends whose own country is X or Y (2-hop traversal;
    //     a future Person.country_id denorm could collapse this to one hop).
    MATCH (friend)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(fCountry:Country)
    WHERE fCountry.name <> $countryXName AND fCountry.name <> $countryYName
    WITH friend
    // (4) Drive from country side: idx_country_name → idx_islocatedin_end →
    //     Comment lookup → date post-filter.
    MATCH (country:Country)<-[:IS_LOCATED_IN]-(msg:Comment)-[:HAS_CREATOR]->(friend)
    WHERE country.name IN [$countryXName, $countryYName]
      AND msg.creationDate >= $startDate AND msg.creationDate < $endDate
    RETURN friend.id, friend.firstName, friend.lastName, country.name
  $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    // (Same pattern, msg:Post arm — AGE 1.6 has no label-OR predicate.)
    MATCH (p:Person {id: $personId})-[:KNOWS]->(d1:Person)
    WHERE d1.id <> $personId
    WITH p, collect(DISTINCT id(d1)) AS direct_ids
    UNWIND CASE WHEN size(direct_ids) = 0 THEN [null] ELSE direct_ids END AS did
    OPTIONAL MATCH (d:Person)-[:KNOWS]->(d2:Person)
      WHERE id(d) = did AND d2 <> p AND NOT id(d2) IN direct_ids
    WITH p, direct_ids, collect(DISTINCT id(d2)) AS foaf_ids
    WITH p, direct_ids + foaf_ids AS all_friend_ids
    UNWIND all_friend_ids AS fid
    MATCH (friend:Person) WHERE id(friend) = fid
    MATCH (friend)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(fCountry:Country)
    WHERE fCountry.name <> $countryXName AND fCountry.name <> $countryYName
    WITH friend
    MATCH (country:Country)<-[:IS_LOCATED_IN]-(msg:Post)-[:HAS_CREATOR]->(friend)
    WHERE country.name IN [$countryXName, $countryYName]
      AND msg.creationDate >= $startDate AND msg.creationDate < $endDate
    RETURN friend.id, friend.firstName, friend.lastName, country.name
  $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
) msgs
GROUP BY friendId, friendFirstName, friendLastName
HAVING SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END) > 0
ORDER BY xyCount DESC, friendId ASC
LIMIT 20;
