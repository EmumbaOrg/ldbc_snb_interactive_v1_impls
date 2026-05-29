-- LdbcUpdate1AddPerson — create a Person vertex with all edges.
-- Cypher-only: a single CREATE + UNWIND call. No side tables maintained.
--
-- Call 1: CREATE Person + IS_LOCATED_IN + HAS_INTEREST + STUDY_AT + WORK_AT in
--         one chained WITH/UNWIND block. RETURN count(*) ensures exactly one row
--         is produced even when $tagIds, $studyAt, or $workAt are empty lists
--         (UNWIND [] produces 0 rows; count(*) aggregates them back to 1).
--
-- PersonPostCount retired Phase B 2026-05-29: the former Call 2 (MATCH the
-- committed Person + seed PPC to 0) had no remaining purpose once PPC was
-- retired — IC10 now computes total post count inline against MessageByCreator.
-- AddPerson is back to a single Cypher call. PersonSide was already retired
-- Phase A 2026-05-28 (IC9 reads firstName/lastName from the Cypher RETURN; IS2
-- uses a GIN scalar subquery).
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
