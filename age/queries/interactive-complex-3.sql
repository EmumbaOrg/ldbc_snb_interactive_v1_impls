SET search_path = ag_catalog, public;
SELECT personId, personFirstName, personLastName, xCount, yCount, (xCount + yCount) AS xyCount
FROM (
  SELECT personId, personFirstName, personLastName,
         SUM(CASE WHEN trim(both '"' from countryName::text) = '$countryXName' THEN 1 ELSE 0 END)::int AS xCount,
         SUM(CASE WHEN trim(both '"' from countryName::text) = '$countryYName' THEN 1 ELSE 0 END)::int AS yCount
  FROM (
    -- 1-hop friends, Comments
    SELECT personId, personFirstName, personLastName, countryName
    FROM cypher('$graphName', $$
      MATCH (person:Person {id: $personId})-[:KNOWS]-(friend:Person)-[:IS_LOCATED_IN]->(friendCity:City)
      WHERE person <> friend
      MATCH (friendCity)-[:IS_PART_OF]->(friendCountry:Country)
      WHERE friendCountry.name <> '$countryXName' AND friendCountry.name <> '$countryYName'
      MATCH (friend)<-[:HAS_CREATOR]-(comment:Comment)-[:IS_LOCATED_IN]->(country:Country)
      WHERE comment.creationDate >= $startDate AND comment.creationDate < $endDate
        AND (country.name = '$countryXName' OR country.name = '$countryYName')
      RETURN friend.id AS personId, friend.firstName AS personFirstName, friend.lastName AS personLastName, country.name AS countryName
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype, countryName agtype)

    UNION ALL

    -- 1-hop friends, Posts
    SELECT personId, personFirstName, personLastName, countryName
    FROM cypher('$graphName', $$
      MATCH (person:Person {id: $personId})-[:KNOWS]-(friend:Person)-[:IS_LOCATED_IN]->(friendCity:City)
      WHERE person <> friend
      MATCH (friendCity)-[:IS_PART_OF]->(friendCountry:Country)
      WHERE friendCountry.name <> '$countryXName' AND friendCountry.name <> '$countryYName'
      MATCH (friend)<-[:HAS_CREATOR]-(post:Post)-[:IS_LOCATED_IN]->(country:Country)
      WHERE post.creationDate >= $startDate AND post.creationDate < $endDate
        AND (country.name = '$countryXName' OR country.name = '$countryYName')
      RETURN friend.id AS personId, friend.firstName AS personFirstName, friend.lastName AS personLastName, country.name AS countryName
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype, countryName agtype)

    UNION ALL

    -- 2-hop friends, Comments
    SELECT personId, personFirstName, personLastName, countryName
    FROM cypher('$graphName', $$
      MATCH (person:Person {id: $personId})-[:KNOWS]-(:Person)-[:KNOWS]-(friend:Person)-[:IS_LOCATED_IN]->(friendCity:City)
      WHERE person <> friend
      MATCH (friendCity)-[:IS_PART_OF]->(friendCountry:Country)
      WHERE friendCountry.name <> '$countryXName' AND friendCountry.name <> '$countryYName'
      MATCH (friend)<-[:HAS_CREATOR]-(comment:Comment)-[:IS_LOCATED_IN]->(country:Country)
      WHERE comment.creationDate >= $startDate AND comment.creationDate < $endDate
        AND (country.name = '$countryXName' OR country.name = '$countryYName')
      RETURN friend.id AS personId, friend.firstName AS personFirstName, friend.lastName AS personLastName, country.name AS countryName
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype, countryName agtype)

    UNION ALL

    -- 2-hop friends, Posts
    SELECT personId, personFirstName, personLastName, countryName
    FROM cypher('$graphName', $$
      MATCH (person:Person {id: $personId})-[:KNOWS]-(:Person)-[:KNOWS]-(friend:Person)-[:IS_LOCATED_IN]->(friendCity:City)
      WHERE person <> friend
      MATCH (friendCity)-[:IS_PART_OF]->(friendCountry:Country)
      WHERE friendCountry.name <> '$countryXName' AND friendCountry.name <> '$countryYName'
      MATCH (friend)<-[:HAS_CREATOR]-(post:Post)-[:IS_LOCATED_IN]->(country:Country)
      WHERE post.creationDate >= $startDate AND post.creationDate < $endDate
        AND (country.name = '$countryXName' OR country.name = '$countryYName')
      RETURN friend.id AS personId, friend.firstName AS personFirstName, friend.lastName AS personLastName, country.name AS countryName
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype, countryName agtype)
  ) all_messages
  GROUP BY personId, personFirstName, personLastName
  HAVING
    SUM(CASE WHEN trim(both '"' from countryName::text) = '$countryXName' THEN 1 ELSE 0 END) > 0
    AND SUM(CASE WHEN trim(both '"' from countryName::text) = '$countryYName' THEN 1 ELSE 0 END) > 0
) agg
ORDER BY xyCount DESC, personId ASC
LIMIT 20
