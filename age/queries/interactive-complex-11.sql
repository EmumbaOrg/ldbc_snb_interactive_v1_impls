-- LdbcQuery11 — Jobs held before workFromYear at companies in a given country, among friends/FoF.
-- Hybrid: two Cypher calls (direct-friend branch, FoF branch) walk KNOWS → WORK_AT → Company →
-- IS_LOCATED_IN → Country and filter by workFrom year. SQL UNION ALL + ORDER + LIMIT.
-- Two-branch UNION ALL: fixed-depth MATCH instead of variable-length path (AGE-QUIRKS §4).
-- FoF branch uses OPTIONAL MATCH direct exclusion pattern (AGE-QUIRKS §10).
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11.

SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)-[work:WORK_AT]->(company:Company)-[:IS_LOCATED_IN]->(:Country {name: $countryName})
    WHERE toInteger(work.workFrom) < $workFromYear AND friend.id <> $personId
    RETURN friend.id, friend.firstName, friend.lastName, company.name, toInteger(work.workFrom)
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          organizationName agtype, organizationWorkFromYear agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
    WITH DISTINCT friend, direct WHERE direct IS NULL
    MATCH (friend)-[work:WORK_AT]->(company:Company)-[:IS_LOCATED_IN]->(:Country {name: $countryName})
    WHERE toInteger(work.workFrom) < $workFromYear
    RETURN friend.id, friend.firstName, friend.lastName, company.name, toInteger(work.workFrom)
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          organizationName agtype, organizationWorkFromYear agtype)
) results
ORDER BY organizationWorkFromYear ASC, personId ASC, organizationName DESC
LIMIT 10;
