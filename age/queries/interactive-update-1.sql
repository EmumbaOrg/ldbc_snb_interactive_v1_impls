-- LdbcUpdate1AddPerson — create a Person vertex with all edges and maintain side-table state.
-- Hybrid: Cypher block creates Person + IS_LOCATED_IN + HAS_INTEREST + STUDY_AT + WORK_AT in
-- one chained WITH/UNWIND block. SQL INSERT maintains:
--   PersonPostCount(person_id)  (iter-2 side table — initialised to 0)
--   PersonSide(person_business_id, first_name, last_name)  (Phase C mirror)
--
-- Person.city_id (iter-1 denorm) was previously written here but had no read
-- consumers — retired 2026-05-14 alongside Forum.moderator_id (see SCHEMA.md).
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
INSERT INTO ldbc_snb."PersonPostCount" (person_id, post_count)
SELECT id, 0 FROM ldbc_snb."Person"
 WHERE CAST(ag_catalog.agtype_object_field_text(properties, 'id') AS bigint) = $personId
ON CONFLICT (person_id) DO NOTHING
;
-- PersonSide mirror. Source names from the just-inserted Person vertex rather
-- than $personFirstName/$personLastName because the driver's convertString()
-- emits Cypher-style backslash escaping ('O\'Brien') that breaks SQL string
-- literals. The Person vertex already has the value stored correctly.
INSERT INTO ldbc_snb."PersonSide" (person_business_id, first_name, last_name)
SELECT
  $personId,
  ag_catalog.agtype_object_field_text(pr.properties, 'firstName'),
  ag_catalog.agtype_object_field_text(pr.properties, 'lastName')
FROM ldbc_snb."Person" pr
WHERE CAST(ag_catalog.agtype_object_field_text(pr.properties, 'id') AS bigint) = $personId
ON CONFLICT (person_business_id) DO NOTHING
;
