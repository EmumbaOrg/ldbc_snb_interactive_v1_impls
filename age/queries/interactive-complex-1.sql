-- LdbcQuery1 — V2: SQL-first with early reachability ∩ firstName intersection.
-- Phase 1: one minimal Cypher call (personId → graphid seed).
-- Phase 2: SQL recursive BFS on KNOWS (unchanged from V1).
-- Phase 3 (NEW): one minimal Cypher call (firstName → graphids only, no OPTIONAL MATCH).
-- Phase 4 (NEW): SQL intersection of reachable ∩ firstName graphids.
-- Phase 5 (NEW): SQL GROUP BY for STUDY_AT / WORK_AT on the small candidate set only,
--   using University.city_id + Company.country_id denorm columns (no extra IS_LOCATED_IN hops).
-- Follows IC12 optimisation pattern: minimal Cypher + denorm SQL.
-- String params ($firstName) stay inside Cypher blocks where convertString binding is correct.

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
  ),
  reachable AS MATERIALIZED (
    SELECT person_id, MIN(dist) AS dist
    FROM reach
    WHERE dist > 0
    GROUP BY person_id
  ),
  -- Minimal Cypher call: firstName → graphids only (no OPTIONAL MATCH, no city/edu/work hops).
  -- GIN on Person.properties handles this. Seed excluded via reachable (dist > 0 above).
  firstname_gids AS MATERIALIZED (
    SELECT (f_gid::text)::ag_catalog.graphid AS person_gid
    FROM cypher('$graphName', $$
      MATCH (f:Person {firstName: $firstName})
      RETURN id(f)
    $$) AS x(f_gid agtype)
  ),
  -- Intersection: reachable ∩ firstName_gids — SQL JOIN so STUDY_AT/WORK_AT only touch this small set.
  candidates AS MATERIALIZED (
    SELECT
      p.id                                                                                                  AS person_gid,
      r.dist,
      p.city_id,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"id"'::ag_catalog.agtype])           AS friend_id,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"lastName"'::ag_catalog.agtype])     AS friend_lastname,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"birthday"'::ag_catalog.agtype])     AS friend_birthday,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"creationDate"'::ag_catalog.agtype]) AS friend_creationdate,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"gender"'::ag_catalog.agtype])       AS friend_gender,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"browserUsed"'::ag_catalog.agtype])  AS friend_browser,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"locationIP"'::ag_catalog.agtype])   AS friend_locationip,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"email"'::ag_catalog.agtype])        AS friend_emails,
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[p.properties, '"speaks"'::ag_catalog.agtype])       AS friend_speaks
    FROM ldbc_snb."Person" p
    JOIN reachable       r  ON r.person_id   = p.id
    JOIN firstname_gids  fg ON fg.person_gid = p.id
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
  c.friend_id                                        AS friendId,
  c.friend_lastname                                  AS friendLastName,
  c.dist::ag_catalog.agtype                          AS distance,
  c.friend_birthday                                  AS friendBirthday,
  c.friend_creationdate                              AS friendCreationDate,
  c.friend_gender                                    AS friendGender,
  c.friend_browser                                   AS friendBrowserUsed,
  c.friend_locationip                                AS friendLocationIp,
  c.friend_emails                                    AS friendEmails,
  c.friend_speaks                                    AS friendLanguages,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[ci.properties, '"name"'::ag_catalog.agtype]) AS friendCityName,
  COALESCE(sa.unis,      '[]'::ag_catalog.agtype)    AS friendUniversities,
  COALESCE(wa.companies, '[]'::ag_catalog.agtype)    AS friendCompanies
FROM candidates c
JOIN ldbc_snb."City" ci ON ci.id = c.city_id
LEFT JOIN study_agg sa ON sa.person_gid = c.person_gid
LEFT JOIN work_agg  wa ON wa.person_gid = c.person_gid
ORDER BY c.dist ASC,
         c.friend_lastname::text ASC,
         (c.friend_id::text::bigint) ASC
LIMIT 20;
