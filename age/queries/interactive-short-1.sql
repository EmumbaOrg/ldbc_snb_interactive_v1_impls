-- LdbcShortQuery1PersonProfile — fetch basic profile for a given person.
-- Pure Cypher: single MATCH (Person)-[:IS_LOCATED_IN]->(City) with inline property projection.
-- No AGE quirks; IS_LOCATED_IN is a typed single-hop — no index or structural concerns.

SELECT * FROM cypher('$graphName', $$
  MATCH (n:Person {id: $personId})-[:IS_LOCATED_IN]->(city:City)
  RETURN n.firstName, n.lastName, n.birthday, n.locationIP, n.browserUsed, city.id, n.gender, n.creationDate
$$) AS (firstName agtype, lastName agtype, birthday agtype, locationIP agtype,
        browserUsed agtype, cityId agtype, gender agtype, creationDate agtype);
