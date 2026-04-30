SET search_path = ag_catalog, public;
SELECT firstName, lastName, birthday, locationIP, browserUsed, cityId, gender, creationDate
FROM cypher('$graphName', $$
  MATCH (n:Person {id: $personId})-[:IS_LOCATED_IN]->(p:City)
  RETURN
    n.firstName AS firstName,
    n.lastName AS lastName,
    n.birthday AS birthday,
    n.locationIP AS locationIP,
    n.browserUsed AS browserUsed,
    p.id AS cityId,
    n.gender AS gender,
    n.creationDate AS creationDate
$$) AS (firstName agtype, lastName agtype, birthday agtype, locationIP agtype,
        browserUsed agtype, cityId agtype, gender agtype, creationDate agtype)
