-- LdbcUpdate1AddPerson — create a Person vertex with all edges and maintain side-table state.
-- Hybrid: two Cypher calls.
--
-- Call 1: CREATE Person + IS_LOCATED_IN + HAS_INTEREST + STUDY_AT + WORK_AT in
--         one chained WITH/UNWIND block. RETURN count(*) ensures exactly one row
--         is produced even when $tagIds, $studyAt, or $workAt are empty lists
--         (UNWIND [] produces 0 rows; count(*) aggregates them back to 1).
-- Call 2: MATCH the just-created Person and RETURN id(p) to seed PersonPostCount.
--         PersonSide retired Phase A 2026-05-28 — IC9 now reads firstName/lastName
--         directly from the Cypher RETURN; IS2 uses a GIN scalar subquery.
--
-- Side tables maintained:
--   PersonPostCount(person_id)  (iter-2, initialised to 0)
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
-- Call 2: MATCH the committed Person and seed PersonPostCount.
-- PersonSide retired Phase A 2026-05-28.
INSERT INTO ldbc_snb."PersonPostCount" (person_id, post_count)
SELECT (new_gid::text)::ag_catalog.graphid, 0
FROM cypher('$graphName', $$
  MATCH (p:Person {id: $personId})
  RETURN id(p) AS new_gid
$$) AS x(new_gid ag_catalog.agtype)
ON CONFLICT (person_id) DO NOTHING;
