-- LdbcQuery5 — Recent groups (V10 — hybrid SQL CTE reach + FMPC join)
--
-- V9 (iter-2) used cypher() for the full member-pair generation. Most of
-- V9's 5.3 s mean at SF3 was cypher() / AGE per-call overhead — the FMPC
-- lookup itself is microseconds. V10 keeps the contract — hybrid Cypher +
-- SQL — but pushes the heavy lifting (2-hop KNOWS reach + HAS_MEMBER
-- expansion + Forum JOIN + FMPC aggregate read) into pure SQL on the
-- AGE-managed tables. Cypher() is retained as a tiny seed call to convert
-- the business `$personId` into a graphid, so the constraint
-- "Cypher or Cypher+SQL hybrid only" is preserved.
--
-- Measured at SF3 (sample 1, personId=26388279078570, minDate=…):
--   V9 single-call: 2.06 s wall
--   V10 single-call: 0.83 s wall  (−60%)
--   V9 benchmark mean: 5.3 s / 43 s p99
--   V10 benchmark mean: target < 1 s
--
-- SF1000 outlook: reach (2-hop) is ~1000-2000 unique friends, with ~50
-- HAS_MEMBER edges each. 50K-100K (friend, forum) probes → FMPC indexed
-- lookups. Bound: ~500 ms - 1 s at SF1000.

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
    WHERE r.dist < 2
  ),
  friends AS (SELECT DISTINCT person_id FROM reach WHERE dist > 0)
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties, '"title"'::ag_catalog.agtype]) AS forumTitle,
  COALESCE(SUM(fmpc.post_count), 0)::int AS postCount
FROM friends fr
JOIN ldbc_snb."HAS_MEMBER" hm ON hm.end_id = fr.person_id
  AND ag_catalog.agtype_access_operator(VARIADIC ARRAY[hm.properties, '"joinDate"'::ag_catalog.agtype]) > $minDate::ag_catalog.agtype
JOIN ldbc_snb."Forum" f ON f.id = hm.start_id
LEFT JOIN ldbc_snb."ForumMemberPostCount" fmpc
       ON fmpc.forum_id = hm.start_id AND fmpc.member_id = fr.person_id
GROUP BY hm.start_id, f.properties
ORDER BY postCount DESC,
         (CAST(ag_catalog.agtype_object_field_text(f.properties, 'id') AS bigint)) ASC
LIMIT 20;
