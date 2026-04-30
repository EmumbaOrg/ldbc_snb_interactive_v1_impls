SET search_path = ag_catalog, public;
SELECT personId, personFirstName, personLastName, organizationName, organizationWorkFromYear
FROM cypher('$graphName', $$
  MATCH (person:Person {id: $personId})-[:KNOWS*1..2]-(friend:Person)
  WHERE person <> friend
  WITH DISTINCT friend
  MATCH (friend)-[workAt:WORK_AT]->(company:Company)
  WHERE workAt.workFrom < $workFromYear AND company.placeName = '$countryName'
  RETURN
    friend.id AS personId,
    friend.firstName AS personFirstName,
    friend.lastName AS personLastName,
    company.name AS organizationName,
    workAt.workFrom AS organizationWorkFromYear
  ORDER BY workAt.workFrom ASC, friend.id ASC, company.name DESC
  LIMIT 10
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        organizationName agtype, organizationWorkFromYear agtype)
