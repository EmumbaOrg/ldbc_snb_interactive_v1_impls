SET search_path = ag_catalog, public;
SELECT * FROM cypher('$graphName', $$
  MATCH (c:City {id: $cityId})
  CREATE (p:Person {
    id: $personId,
    firstName: '$personFirstName',
    lastName: '$personLastName',
    gender: '$gender',
    birthday: $birthday,
    creationDate: $creationDate,
    locationIP: '$locationIP',
    browserUsed: '$browserUsed',
    languages: $languages,
    email: $emails
  })-[:IS_LOCATED_IN]->(c)
  WITH p
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (p)-[:HAS_INTEREST]->(t)
  WITH p
  UNWIND $studyAt AS s
    MATCH (u:University {id: s.organizationId})
    CREATE (p)-[:STUDY_AT {classYear: s.year}]->(u)
  WITH p
  UNWIND $workAt AS w
    MATCH (comp:Company {id: w.organizationId})
    CREATE (p)-[:WORK_AT {workFrom: w.year}]->(comp)
  RETURN p.id AS result
$$) AS (result agtype)
