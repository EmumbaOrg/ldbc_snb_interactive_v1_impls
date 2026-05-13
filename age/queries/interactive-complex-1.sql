-- LdbcQuery1 — V4b: All graph access through Cypher; outer SQL only deduplicates and sorts.
-- Pattern: AGENTS.md "Hybrid" tier — Cypher handles all traversal and property access;
--   outer SQL performs UNION ALL + DISTINCT ON (min-distance dedup) + ORDER BY + LIMIT.
-- No AGE graph table accessed directly in outer SQL.
-- All KNOWS traversal directed (-[:KNOWS]->) per AGE-QUIRKS section 11; IU8 stores bidirectionally.
-- hop1/hop2/hop3: {firstName: $firstName} inlined on terminal node (AGE-QUIRKS section 8: GIN lookup).
-- hop2/hop3: WITH DISTINCT mid materialises the k-hop friend set before expanding the next hop,
--   binding the intermediate node so AGE expands forward via idx_knows_start (prevents backward
--   firstName-scan + temp-spill pathology documented in AGE-QUIRKS section 4).
-- Each hop arm applies WITH DISTINCT f before the OPTIONAL MATCH chains to ensure each friend is
--   aggregated exactly once — required when the same friend is reachable via multiple paths.
-- WORK_AT OPTIONAL MATCH split into two 1-hop steps with intermediate WITH to break the planner's
--   tendency to build a full Company×IS_LOCATED_IN×Country×WORK_AT hash (143K rows, disk spill).
--   Splitting forces binding of (f) and (co) separately so AGE can use idx_workat_start and
--   idx_islocatedin_start per candidate rather than a full backward hash join.
-- STUDY_AT aggregation uses the combined 2-hop pattern (already uses idx_studyat_start correctly).
-- toString() applied to integer fields (classYear, workFrom) to maintain the agtype-string array
--   format expected by the LDBC Java driver result consumer.
-- Outer dedup: DISTINCT ON (friend_id bigint) ordered by dist ASC picks the minimum-distance row
--   for each person — equivalent to the MIN(dist) GROUP BY candidates approach used in V3.

WITH
  hop1 AS (
    SELECT
      friend_id, friend_lastname, dist, friend_birthday, friend_creationdate,
      friend_gender, friend_browser, friend_locationip, friend_emails, friend_speaks,
      friend_cityname, friend_universities, friend_companies
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(f:Person {firstName: $firstName})
      WHERE f.id <> $personId
      WITH DISTINCT f
      OPTIONAL MATCH (f)-[:IS_LOCATED_IN]->(city:City)
      OPTIONAL MATCH (f)-[sa:STUDY_AT]->(u:University)-[:IS_LOCATED_IN]->(uc:City)
      WITH f, city,
           collect(CASE WHEN u IS NOT NULL
                        THEN [u.name, toString(sa.classYear), uc.name]
                        ELSE null END) AS unis
      OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)
      WITH f, city, unis, wa, co
      OPTIONAL MATCH (co)-[:IS_LOCATED_IN]->(cc:Country)
      WITH f, city, unis,
           collect(CASE WHEN co IS NOT NULL
                        THEN [co.name, toString(wa.workFrom), cc.name]
                        ELSE null END) AS companies
      RETURN f.id, f.lastName, 1 AS dist,
             f.birthday, f.creationDate, f.gender, f.browserUsed, f.locationIP,
             f.email, f.speaks, city.name, unis, companies
    $$) AS x(
      friend_id agtype, friend_lastname agtype, dist agtype,
      friend_birthday agtype, friend_creationdate agtype,
      friend_gender agtype, friend_browser agtype, friend_locationip agtype,
      friend_emails agtype, friend_speaks agtype,
      friend_cityname agtype, friend_universities agtype, friend_companies agtype
    )
  ),
  -- hop2: WITH DISTINCT mid materialises 1-hop friends before expanding the 2nd hop, binding
  -- the intermediate node so AGE expands forward via idx_knows_start (prevents backward firstName-scan).
  hop2 AS (
    SELECT
      friend_id, friend_lastname, dist, friend_birthday, friend_creationdate,
      friend_gender, friend_browser, friend_locationip, friend_emails, friend_speaks,
      friend_cityname, friend_universities, friend_companies
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(mid:Person)
      WITH DISTINCT mid
      MATCH (mid)-[:KNOWS]->(f:Person {firstName: $firstName})
      WHERE f.id <> $personId
      WITH DISTINCT f
      OPTIONAL MATCH (f)-[:IS_LOCATED_IN]->(city:City)
      OPTIONAL MATCH (f)-[sa:STUDY_AT]->(u:University)-[:IS_LOCATED_IN]->(uc:City)
      WITH f, city,
           collect(CASE WHEN u IS NOT NULL
                        THEN [u.name, toString(sa.classYear), uc.name]
                        ELSE null END) AS unis
      OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)
      WITH f, city, unis, wa, co
      OPTIONAL MATCH (co)-[:IS_LOCATED_IN]->(cc:Country)
      WITH f, city, unis,
           collect(CASE WHEN co IS NOT NULL
                        THEN [co.name, toString(wa.workFrom), cc.name]
                        ELSE null END) AS companies
      RETURN f.id, f.lastName, 2 AS dist,
             f.birthday, f.creationDate, f.gender, f.browserUsed, f.locationIP,
             f.email, f.speaks, city.name, unis, companies
    $$) AS x(
      friend_id agtype, friend_lastname agtype, dist agtype,
      friend_birthday agtype, friend_creationdate agtype,
      friend_gender agtype, friend_browser agtype, friend_locationip agtype,
      friend_emails agtype, friend_speaks agtype,
      friend_cityname agtype, friend_universities agtype, friend_companies agtype
    )
  ),
  -- hop3: two-phase traversal. WITH DISTINCT mid binds the 2-hop set so the second MATCH
  -- expands forward from each mid via idx_knows_start. WITH DISTINCT f before aggregation
  -- prevents duplicate OPTIONAL MATCH executions when multiple mid nodes reach the same f.
  hop3 AS (
    SELECT
      friend_id, friend_lastname, dist, friend_birthday, friend_creationdate,
      friend_gender, friend_browser, friend_locationip, friend_emails, friend_speaks,
      friend_cityname, friend_universities, friend_companies
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(mid:Person)
      WHERE mid.id <> $personId
      WITH DISTINCT mid
      MATCH (mid)-[:KNOWS]->(f:Person {firstName: $firstName})
      WHERE f.id <> $personId
      WITH DISTINCT f
      OPTIONAL MATCH (f)-[:IS_LOCATED_IN]->(city:City)
      OPTIONAL MATCH (f)-[sa:STUDY_AT]->(u:University)-[:IS_LOCATED_IN]->(uc:City)
      WITH f, city,
           collect(CASE WHEN u IS NOT NULL
                        THEN [u.name, toString(sa.classYear), uc.name]
                        ELSE null END) AS unis
      OPTIONAL MATCH (f)-[wa:WORK_AT]->(co:Company)
      WITH f, city, unis, wa, co
      OPTIONAL MATCH (co)-[:IS_LOCATED_IN]->(cc:Country)
      WITH f, city, unis,
           collect(CASE WHEN co IS NOT NULL
                        THEN [co.name, toString(wa.workFrom), cc.name]
                        ELSE null END) AS companies
      RETURN f.id, f.lastName, 3 AS dist,
             f.birthday, f.creationDate, f.gender, f.browserUsed, f.locationIP,
             f.email, f.speaks, city.name, unis, companies
    $$) AS x(
      friend_id agtype, friend_lastname agtype, dist agtype,
      friend_birthday agtype, friend_creationdate agtype,
      friend_gender agtype, friend_browser agtype, friend_locationip agtype,
      friend_emails agtype, friend_speaks agtype,
      friend_cityname agtype, friend_universities agtype, friend_companies agtype
    )
  )
SELECT
  friend_id          AS friendId,
  friend_lastname    AS friendLastName,
  dist               AS distance,
  friend_birthday    AS friendBirthday,
  friend_creationdate AS friendCreationDate,
  friend_gender      AS friendGender,
  friend_browser     AS friendBrowserUsed,
  friend_locationip  AS friendLocationIp,
  friend_emails      AS friendEmails,
  friend_speaks      AS friendLanguages,
  friend_cityname    AS friendCityName,
  friend_universities AS friendUniversities,
  friend_companies   AS friendCompanies
FROM (
  SELECT DISTINCT ON ((friend_id::text::bigint))
    friend_id, friend_lastname, dist, friend_birthday, friend_creationdate,
    friend_gender, friend_browser, friend_locationip, friend_emails, friend_speaks,
    friend_cityname, friend_universities, friend_companies
  FROM (
    SELECT * FROM hop1
    UNION ALL SELECT * FROM hop2
    UNION ALL SELECT * FROM hop3
  ) all_hops
  ORDER BY (friend_id::text::bigint), (dist::text::int) ASC
) deduped
ORDER BY (dist::text::int) ASC,
         friend_lastname::text ASC,
         (friend_id::text::bigint) ASC
LIMIT 20;
