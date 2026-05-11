-- LdbcQuery1 — Persons within 3 KNOWS-hops matching a firstName, with bio data, sorted by distance.
-- Hybrid: Cypher seed call converts $personId to graphid; SQL recursive CTE walks KNOWS 1-3 hops
-- (BFS with MIN-distance per node); second Cypher call fetches firstName-matching candidates with
-- city/university/company data via OPTIONAL MATCH; SQL JOIN filters by reach and orders.
-- 3-hop variable-length Cypher hits path-enumeration at scale (AGE-QUIRKS §4) — SQL CTE is the fix.
-- Directed `-[:KNOWS]->` traversal per AGE-QUIRKS §11 (IU8 stores both directions).
-- TODO: when gin_person firstName selectivity weakens at SF1000+, add a btree index on
--       extracted firstName and rewrite the Cypher candidates call as a SQL scan.

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
