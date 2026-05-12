-- LdbcQuery1 — V3: Cypher-first hybrid (three explicit hop arms + SQL aggregation).
-- Pattern: AGENTS.md "Hybrid" tier + AGE-QUIRKS section 4 (canonical IC1 form).
-- All KNOWS traversal directed (-[:KNOWS]->) per AGE-QUIRKS section 11; IU8 stores bidirectionally.
-- firstName filter inlined as {firstName: $firstName} on the terminal node so AGE uses GIN
--   (AGE-QUIRKS section 8: only inline node-pattern maps trigger GIN containment lookup).
-- Each hop returns only id(f) (graphid) — bio properties are extracted in outer SQL by
-- joining Person on the candidate graphid set (avoids agtype encode/decode of 10 fields
-- inside the Cypher blocks; same pattern as IC9/IC2).
-- Outer SQL: UNION ALL across the hop arms + MIN(dist) GROUP BY person_gid gives the
-- shortest-distance semantics with natural dedup (matches IC9 V4 commentary in section 10).
-- STUDY_AT/WORK_AT aggregation uses University.city_id and Company.country_id denorm columns
-- (avoids one IS_LOCATED_IN hop per row; same idea as the IC12 optimization).

WITH
  hop1 AS (
    SELECT (gid::text)::ag_catalog.graphid AS person_gid, 1 AS dist
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(f:Person {firstName: $firstName})
      WHERE f.id <> $personId
      RETURN id(f)
    $$) AS x(gid agtype)
  ),
  hop2 AS (
    SELECT (gid::text)::ag_catalog.graphid AS person_gid, 2 AS dist
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(f:Person {firstName: $firstName})
      WHERE f.id <> $personId
      RETURN DISTINCT id(f)
    $$) AS x(gid agtype)
  ),
  hop3 AS (
    SELECT (gid::text)::ag_catalog.graphid AS person_gid, 3 AS dist
    FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(:Person)-[:KNOWS]->(f:Person {firstName: $firstName})
      WHERE f.id <> $personId
      RETURN DISTINCT id(f)
    $$) AS x(gid agtype)
  ),
  candidates AS MATERIALIZED (
    SELECT person_gid, MIN(dist) AS dist
    FROM (
      SELECT * FROM hop1
      UNION ALL SELECT * FROM hop2
      UNION ALL SELECT * FROM hop3
    ) u
    GROUP BY person_gid
  ),
  bio AS MATERIALIZED (
    SELECT
      c.person_gid, c.dist, p.city_id,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"id"'::ag_catalog.agtype])           AS friend_id,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"lastName"'::ag_catalog.agtype])     AS friend_lastname,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"birthday"'::ag_catalog.agtype])     AS friend_birthday,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"creationDate"'::ag_catalog.agtype]) AS friend_creationdate,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"gender"'::ag_catalog.agtype])       AS friend_gender,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"browserUsed"'::ag_catalog.agtype])  AS friend_browser,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"locationIP"'::ag_catalog.agtype])   AS friend_locationip,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"email"'::ag_catalog.agtype])        AS friend_emails,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"speaks"'::ag_catalog.agtype])       AS friend_speaks
    FROM candidates c
    JOIN ldbc_snb."Person" p ON p.id = c.person_gid
  ),
  -- STUDY_AT aggregation: only for candidates (small set). Uses idx_studyat_start + University.city_id denorm.
  -- agtype_object_field_text strips agtype quotes; all fields stored as agtype strings so re-add "..." in array.
  study_agg AS (
    SELECT
      sa.start_id AS person_gid,
      (
        '[' || string_agg(
          '["' || ag_catalog.agtype_object_field_text(u.properties,  'name')      || '",' ||
          '"'  || ag_catalog.agtype_object_field_text(sa.properties, 'classYear') || '",' ||
          '"'  || ag_catalog.agtype_object_field_text(uc.properties, 'name')      || '"]',
          ','
        ) || ']'
      )::ag_catalog.agtype AS unis
    FROM ldbc_snb."STUDY_AT" sa
    JOIN ldbc_snb."University" u  ON u.id  = sa.end_id
    JOIN ldbc_snb."City"       uc ON uc.id = u.city_id
    WHERE sa.start_id IN (SELECT person_gid FROM candidates)
    GROUP BY sa.start_id
  ),
  -- WORK_AT aggregation: only for candidates. Uses idx_workat_start + Company.country_id denorm.
  work_agg AS (
    SELECT
      wa.start_id AS person_gid,
      (
        '[' || string_agg(
          '["' || ag_catalog.agtype_object_field_text(co.properties, 'name')     || '",' ||
          '"'  || ag_catalog.agtype_object_field_text(wa.properties, 'workFrom') || '",' ||
          '"'  || ag_catalog.agtype_object_field_text(cc.properties, 'name')     || '"]',
          ','
        ) || ']'
      )::ag_catalog.agtype AS companies
    FROM ldbc_snb."WORK_AT" wa
    JOIN ldbc_snb."Company" co  ON co.id  = wa.end_id
    JOIN ldbc_snb."Country" cc  ON cc.id  = co.country_id
    WHERE wa.start_id IN (SELECT person_gid FROM candidates)
    GROUP BY wa.start_id
  )
SELECT
  b.friend_id                                        AS friendId,
  b.friend_lastname                                  AS friendLastName,
  b.dist::ag_catalog.agtype                          AS distance,
  b.friend_birthday                                  AS friendBirthday,
  b.friend_creationdate                              AS friendCreationDate,
  b.friend_gender                                    AS friendGender,
  b.friend_browser                                   AS friendBrowserUsed,
  b.friend_locationip                                AS friendLocationIp,
  b.friend_emails                                    AS friendEmails,
  b.friend_speaks                                    AS friendLanguages,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[ci.properties, '"name"'::ag_catalog.agtype]) AS friendCityName,
  COALESCE(sa.unis,      '[]'::ag_catalog.agtype)    AS friendUniversities,
  COALESCE(wa.companies, '[]'::ag_catalog.agtype)    AS friendCompanies
FROM bio b
JOIN ldbc_snb."City" ci ON ci.id = b.city_id
LEFT JOIN study_agg sa ON sa.person_gid = b.person_gid
LEFT JOIN work_agg  wa ON wa.person_gid = b.person_gid
ORDER BY b.dist ASC,
         b.friend_lastname::text ASC,
         (b.friend_id::text::bigint) ASC
LIMIT 20;
