-- LdbcUpdate1AddPerson — create a Person vertex with all edges and maintain side-table state.
-- Hybrid: two Cypher calls.
--
-- Call 1: CREATE Person + IS_LOCATED_IN + HAS_INTEREST + STUDY_AT + WORK_AT in
--         one chained WITH/UNWIND block. RETURN count(*) ensures exactly one row
--         is produced even when $tagIds, $studyAt, or $workAt are empty lists
--         (UNWIND [] produces 0 rows; count(*) aggregates them back to 1).
-- Call 2: MATCH the just-created Person and RETURN id(p), p.firstName, p.lastName.
--         Feeds PersonPostCount and PersonSide via a writable CTE so outer SQL
--         never reads the AGE Person label table (AGENTS.md §14).
--         firstName/lastName sourced from Cypher RETURN (not $personFirstName /
--         $personLastName) because the driver's convertString() emits Cypher-style
--         backslash escaping ('O\'Brien') that breaks SQL string literals.
--         agtype string ::text removes the JSON quotes — verified: fn::text for a
--         Cypher-returned property yields the bare unquoted text.
--
-- Side tables maintained:
--   PersonPostCount(person_id)                    (iter-2, initialised to 0)
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
-- Call 2: MATCH the committed Person and feed both side tables in one statement
-- via a writable CTE. The intermediate insert_ppc CTE consumes new_person for
-- PersonPostCount; the outer INSERT consumes new_person again for PersonSide.
-- Both run atomically in one SQL statement so new_person is evaluated once.
WITH new_person AS (
  SELECT
    (new_gid::text)::ag_catalog.graphid AS person_gid,
    fn::text                            AS first_name,
    ln::text                            AS last_name
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})
    RETURN id(p) AS new_gid, p.firstName AS fn, p.lastName AS ln
  $$) AS x(new_gid ag_catalog.agtype, fn ag_catalog.agtype, ln ag_catalog.agtype)
),
insert_ppc AS (
  INSERT INTO ldbc_snb."PersonPostCount" (person_id, post_count)
  SELECT person_gid, 0 FROM new_person
  ON CONFLICT (person_id) DO NOTHING
  RETURNING person_id
)
INSERT INTO ldbc_snb."PersonSide" (person_business_id, first_name, last_name)
SELECT
  $personId,
  np.first_name,
  np.last_name
FROM new_person np
ON CONFLICT (person_business_id) DO NOTHING
;
