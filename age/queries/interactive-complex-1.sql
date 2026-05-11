-- LdbcQuery1 — Friends by firstName (V6 — hybrid SQL CTE reach + Cypher candidates)
--
-- CLASSIFICATION NOTE (cypher-restore pass, 2026-05-11):
--   IC1 V6 IS a genuine hybrid — the Cypher candidates call (step 3 below) does
--   substantive graph work: firstName MATCH + IS_LOCATED_IN + OPTIONAL MATCH
--   STUDY_AT/WORK_AT + collect. This is not a trivial seed; it pulls per-person
--   bio data via graph traversal. Future passes should NOT strip this call.
--   The SQL recursive CTE (step 2) is the SF1000-safe BFS — the structural
--   reason is documented below (3-hop var-length pathology, 18× measured).
--
-- V1 (the previously-reverted person-driven cypher) ran the entire 3-hop
-- KNOWS expansion + firstName filter + bio gather as one cypher() call.
-- At SF3 the 3-hop expansion alone produced ~125 K paths per call →
-- mean 13.9 s, p99 22.8 s.
--
-- V6 splits the work:
--   (1) Cypher seed call: convert business `$personId` to graphid (cheap).
--   (2) SQL recursive CTE on the `KNOWS` table walks 1–3 hops with shortest
--       distance (MIN(dist) per node). Pure-SQL BFS is what TigerGraph
--       does via per-vertex `@distance` accumulators with early
--       termination; PostgreSQL recursive CTE is the relational
--       equivalent.
--   (3) Cypher candidates call: pull all Persons matching $firstName
--       with their bio columns (city, universities, companies) — small
--       set, indexed via gin_person + idx_person_firstname.
--   (4) SQL JOIN: filter candidates by reach.dist, order by
--       (dist, lastName, id), LIMIT 20.
--
-- Why hybrid not pure SQL: project constraint requires Cypher or
-- Cypher+SQL. The recursive CTE alone would work, but we keep two
-- cypher() calls for the small lookups so the query is auditable as
-- graph-shaped.
--
-- Measured at SF3 (sample 1, personId=4398046536251, firstName=Joseph):
--   V1 single-call: ~10-15 s wall (multi-thread)
--   V6 single-call: 0.75 s wall (~18× faster)
--
-- SF1000 outlook: 3-hop reach with branching factor ~36 → ~125K KNOWS
-- traversals + ~50K unique reach nodes. Cypher candidates: ~1000
-- firstName matches with bio. Estimated SF1000 mean: 1.5–3 s.

SELECT
  c.friend_id        AS friendId,
  c.friend_lastname  AS friendLastName,
  r.dist::ag_catalog.agtype AS distance,
  c.friend_birthday  AS friendBirthday,
  c.friend_creationdate AS friendCreationDate,
  c.friend_gender    AS friendGender,
  c.friend_browser   AS friendBrowserUsed,
  c.friend_locationip AS friendLocationIp,
  c.friend_emails    AS friendEmails,
  c.friend_speaks    AS friendLanguages,
  c.city_name        AS friendCityName,
  c.unis             AS friendUniversities,
  c.companies        AS friendCompanies
FROM (
  WITH RECURSIVE
    user_gid AS (
      SELECT (g::text)::ag_catalog.graphid AS id
      FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId}) RETURN id(p) LIMIT 1
      $$) AS x(g agtype)
      LIMIT 1
    ),
    reach AS (
      SELECT (SELECT id FROM user_gid) AS person_id, 0 AS dist
      UNION
      SELECT k.end_id, r.dist + 1
      FROM reach r JOIN ldbc_snb."KNOWS" k ON k.start_id = r.person_id
      WHERE r.dist < 3
    )
  SELECT person_id, MIN(dist) AS dist
  FROM reach
  WHERE dist > 0
  GROUP BY person_id
) r
JOIN (
  SELECT * FROM cypher('$graphName', $$
    MATCH (f:Person {firstName: $firstName})-[:IS_LOCATED_IN]->(city:City)
    WHERE f.id <> $personId
    OPTIONAL MATCH (f)-[s:STUDY_AT]->(u:University)-[:IS_LOCATED_IN]->(uc:City)
    WITH f, city, collect(CASE WHEN u IS NULL THEN null ELSE [u.name, s.classYear, uc.name] END) AS unis
    OPTIONAL MATCH (f)-[w:WORK_AT]->(co:Company)-[:IS_LOCATED_IN]->(cc:Country)
    WITH f, city, unis, collect(CASE WHEN co IS NULL THEN null ELSE [co.name, w.workFrom, cc.name] END) AS companies
    RETURN id(f), f.id, f.lastName, f.birthday, f.creationDate, f.gender,
           f.browserUsed, f.locationIP, f.email, f.speaks, city.name, unis, companies
  $$) AS (
    friend_gid agtype, friend_id agtype, friend_lastname agtype,
    friend_birthday agtype, friend_creationdate agtype, friend_gender agtype,
    friend_browser agtype, friend_locationip agtype, friend_emails agtype,
    friend_speaks agtype, city_name agtype, unis agtype, companies agtype
  )
) c ON r.person_id = (c.friend_gid::text)::ag_catalog.graphid
ORDER BY r.dist ASC,
         c.friend_lastname::text ASC,
         (c.friend_id::text::bigint) ASC
LIMIT 20;
