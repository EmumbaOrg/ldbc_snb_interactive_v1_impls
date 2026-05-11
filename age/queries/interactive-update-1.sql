-- LdbcUpdate1AddPerson — create a Person vertex with all edges and maintain denorm state.
-- Hybrid: Cypher block creates Person + IS_LOCATED_IN + HAS_INTEREST + STUDY_AT + WORK_AT in
-- one chained WITH/UNWIND block. SQL UPDATE/INSERT maintains:
--   Person.city_id              (iter-1 column denorm)
--   PersonPostCount(person_id)  (iter-2 side table — initialised to 0)
SELECT * FROM cypher('$graphName', $$
  MATCH (city:City {id: $cityId})
  CREATE (p:Person {
    id: $personId,
    firstName: $personFirstName,
    lastName: $personLastName,
    gender: $gender,
    birthday: $birthday,
    birthMonth: $birthMonth,
    birthDay: $birthDay,
    creationDate: $creationDate,
    locationIP: $locationIP,
    browserUsed: $browserUsed,
    speaks: $languages,
    email: $emails
  })-[:IS_LOCATED_IN]->(city)
  WITH p, count(*) AS dummy1
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (p)-[:HAS_INTEREST]->(t)
  WITH p, count(*) AS dummy2
  UNWIND $studyAt AS s
    MATCH (u:University {id: s.organizationId})
    CREATE (p)-[:STUDY_AT {classYear: s.year}]->(u)
  WITH p, count(*) AS dummy3
  UNWIND $workAt AS w
    MATCH (comp:Company {id: w.organizationId})
    CREATE (p)-[:WORK_AT {workFrom: w.year}]->(comp)
  RETURN count(*)
$$) AS (result agtype);
UPDATE ldbc_snb."Person" pr
   SET city_id = (SELECT end_id FROM ldbc_snb."IS_LOCATED_IN" WHERE start_id = pr.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(pr.properties, 'id') AS bigint) = $personId
;
INSERT INTO ldbc_snb."PersonPostCount" (person_id, post_count)
SELECT id, 0 FROM ldbc_snb."Person"
 WHERE CAST(ag_catalog.agtype_object_field_text(properties, 'id') AS bigint) = $personId
ON CONFLICT (person_id) DO NOTHING
;
