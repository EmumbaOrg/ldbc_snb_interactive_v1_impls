-- LdbcQuery3 — Friends and friends-of-friends with messages in two countries
--
-- Why this is a single cypher() call instead of the original 4-branch UNION ALL:
--   The original Cypher (kept commented at the bottom) was four cypher() calls:
--     1. direct + Comment           ─┬─ each computed friends-of-friends from
--     2. direct + Post              ─┤   scratch and applied the country filter
--     3. friends-of-friends + Comment─┤  AFTER materialising every message by
--     4. friends-of-friends + Post  ─┴─  every (1+2-hop) friend in the date window.
--   At SF0.1 the FoF branches alone materialised 119 175 candidate rows each,
--   and the country-name filter (~1-in-50 selective) was applied last.
--   Measured at SF0.1: planning 90 ms, execution 317 ms, 946 438 buffers hit,
--   total ~407 ms wall.
--
--   The C8 form below — single cypher() call, friend set computed *once* — is
--   ~10-12x faster on the SF0.1 samples we tested while preserving Cypher
--   fidelity (no drop to raw SQL like SQ6/IS4/IC9 needed). Strategy:
--     1. Compute direct + 2-hop friend SET in one pass; collect *graphids only*
--        (id(d1), id(d2)) instead of full vertex objects so the Sort+Unique
--        runs on 8-byte values, not ~500-byte agtype Person blobs. This is the
--        key SF1000 win — at 10 000 friends, full-vertex collect produces a
--        ~5 MB agtype list whose internal Sort+GroupAggregate dominates.
--     2. Re-MATCH each friend by graphid before traversing — the per-friend
--        idx_person_graphid lookup costs ~0.005 ms; cheaper than the saved
--        Sort+Unique on full vertices at any non-trivial scale.
--     3. Drive the message scan from the country side
--        (`(country:Country)<-[:IS_LOCATED_IN]-(msg)<-[:HAS_CREATOR]-(friend)`)
--        rather than friend → HAS_CREATOR → msg → country. The country.name
--        IN [...] filter resolves to 2 rows, then idx_islocatedin_end gives
--        the in-country messages directly. Date filter is applied as a post-
--        filter on Comment/Post — see Future Step #2 below for how to push it
--        into a composite index at SF1000.
--     4. Two-arm UNION ALL inside one cypher() (Comment, Post). Cannot be
--        merged because AGE 1.6 doesn't support label-OR predicates
--        (`msg:Comment OR msg:Post` → "syntax error at or near :").
--
--   Outer SQL still does the SUM(CASE...)/HAVING/ORDER/LIMIT aggregation —
--   country names are referenced both inside cypher() and in the outer
--   aggregation, which is why IC3 stays excluded from age_parameterized_queries
--   (the parameterized path only injects `?` agtype params into cypher()
--   bodies; outer-SQL params aren't substituted).
--
-- Original Cypher implementation, kept for reference:
-- ----------------------------------------------------------------------------
-- SELECT friendId, friendFirstName, friendLastName,
--        SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END)::int AS xCount,
--        SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END)::int AS yCount,
--        COUNT(*)::int AS xyCount
-- FROM (
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)<-[:HAS_CREATOR]-(msg:Comment)-[:IS_LOCATED_IN]->(country:Country),
--           (friend)-[:IS_LOCATED_IN]->(fCity:City)-[:IS_PART_OF]->(fCountry:Country)
--     WHERE msg.creationDate >= $startDate AND msg.creationDate < $endDate
--       AND country.name IN [$countryXName, $countryYName]
--       AND fCountry.name <> $countryXName AND fCountry.name <> $countryYName
--     RETURN friend.id, friend.firstName, friend.lastName, country.name
--   $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
--   UNION ALL
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)<-[:HAS_CREATOR]-(msg:Post)-[:IS_LOCATED_IN]->(country:Country),
--           (friend)-[:IS_LOCATED_IN]->(fCity:City)-[:IS_PART_OF]->(fCountry:Country)
--     WHERE msg.creationDate >= $startDate AND msg.creationDate < $endDate
--       AND country.name IN [$countryXName, $countryYName]
--       AND fCountry.name <> $countryXName AND fCountry.name <> $countryYName
--     RETURN friend.id, friend.firstName, friend.lastName, country.name
--   $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
--   UNION ALL
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
--     WHERE friend.id <> $personId
--     OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
--     WITH DISTINCT friend, direct WHERE direct IS NULL
--     MATCH (friend)<-[:HAS_CREATOR]-(msg:Comment)-[:IS_LOCATED_IN]->(country:Country),
--           (friend)-[:IS_LOCATED_IN]->(fCity:City)-[:IS_PART_OF]->(fCountry:Country)
--     WHERE msg.creationDate >= $startDate AND msg.creationDate < $endDate
--       AND country.name IN [$countryXName, $countryYName]
--       AND fCountry.name <> $countryXName AND fCountry.name <> $countryYName
--     RETURN friend.id, friend.firstName, friend.lastName, country.name
--   $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
--   UNION ALL
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
--     WHERE friend.id <> $personId
--     OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
--     WITH DISTINCT friend, direct WHERE direct IS NULL
--     MATCH (friend)<-[:HAS_CREATOR]-(msg:Post)-[:IS_LOCATED_IN]->(country:Country),
--           (friend)-[:IS_LOCATED_IN]->(fCity:City)-[:IS_PART_OF]->(fCountry:Country)
--     WHERE msg.creationDate >= $startDate AND msg.creationDate < $endDate
--       AND country.name IN [$countryXName, $countryYName]
--       AND fCountry.name <> $countryXName AND fCountry.name <> $countryYName
--     RETURN friend.id, friend.firstName, friend.lastName, country.name
--   $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
-- ) msgs
-- GROUP BY friendId, friendFirstName, friendLastName
-- HAVING SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END) > 0
--    AND SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END) > 0
-- ORDER BY xyCount DESC, friendId ASC
-- LIMIT 20;
-- ----------------------------------------------------------------------------

SELECT friendId, friendFirstName, friendLastName,
       SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END)::int AS xCount,
       SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END)::int AS yCount,
       COUNT(*)::int AS xyCount
FROM (
  SELECT * FROM cypher('$graphName', $$
    // (1) Compute direct + 2-hop friend graphids in a single pass.
    MATCH (p:Person {id: $personId})-[:KNOWS]->(d1:Person)
    WHERE d1.id <> $personId
    WITH p, collect(DISTINCT id(d1)) AS direct_ids
    UNWIND CASE WHEN size(direct_ids) = 0 THEN [null] ELSE direct_ids END AS did
    OPTIONAL MATCH (d:Person)-[:KNOWS]->(d2:Person)
      WHERE id(d) = did AND d2 <> p AND NOT id(d2) IN direct_ids
    WITH p, direct_ids, collect(DISTINCT id(d2)) AS foaf_ids
    WITH p, direct_ids + foaf_ids AS all_friend_ids
    // (2) Re-MATCH each friend by graphid (cheap idx_person_graphid lookup).
    UNWIND all_friend_ids AS fid
    MATCH (friend:Person) WHERE id(friend) = fid
    // (3) Filter out friends whose own country is X or Y (2-hop traversal —
    //     see Future Step #1 for how to denormalise this).
    MATCH (friend)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(fCountry:Country)
    WHERE fCountry.name <> $countryXName AND fCountry.name <> $countryYName
    WITH friend
    // (4) Drive from country side: idx_country_name → idx_islocatedin_end →
    //     Comment lookup → date post-filter.
    MATCH (country:Country)<-[:IS_LOCATED_IN]-(msg:Comment)<-[:HAS_CREATOR]-(friend)
    WHERE country.name IN [$countryXName, $countryYName]
      AND msg.creationDate >= $startDate AND msg.creationDate < $endDate
    RETURN friend.id, friend.firstName, friend.lastName, country.name
  $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    // (Same pattern, msg:Post arm — AGE 1.6 has no label-OR predicate.)
    MATCH (p:Person {id: $personId})-[:KNOWS]->(d1:Person)
    WHERE d1.id <> $personId
    WITH p, collect(DISTINCT id(d1)) AS direct_ids
    UNWIND CASE WHEN size(direct_ids) = 0 THEN [null] ELSE direct_ids END AS did
    OPTIONAL MATCH (d:Person)-[:KNOWS]->(d2:Person)
      WHERE id(d) = did AND d2 <> p AND NOT id(d2) IN direct_ids
    WITH p, direct_ids, collect(DISTINCT id(d2)) AS foaf_ids
    WITH p, direct_ids + foaf_ids AS all_friend_ids
    UNWIND all_friend_ids AS fid
    MATCH (friend:Person) WHERE id(friend) = fid
    MATCH (friend)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(fCountry:Country)
    WHERE fCountry.name <> $countryXName AND fCountry.name <> $countryYName
    WITH friend
    MATCH (country:Country)<-[:IS_LOCATED_IN]-(msg:Post)<-[:HAS_CREATOR]-(friend)
    WHERE country.name IN [$countryXName, $countryYName]
      AND msg.creationDate >= $startDate AND msg.creationDate < $endDate
    RETURN friend.id, friend.firstName, friend.lastName, country.name
  $$) AS (friendId agtype, friendFirstName agtype, friendLastName agtype, countryName agtype)
) msgs
GROUP BY friendId, friendFirstName, friendLastName
HAVING SUM(CASE WHEN countryName::text = $countryXName THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN countryName::text = $countryYName THEN 1 ELSE 0 END) > 0
ORDER BY xyCount DESC, friendId ASC
LIMIT 20;

-- ----------------------------------------------------------------------------
-- Future optimization steps (queue when SF100+ benchmarks demand it):
--
-- 1. Denormalize Person.country onto the Person vertex (mirrors the IC10
--    Phase F birthMonth/birthDay precomputation). Populate `country_id`
--    (graphid) or `country_name` (text) at IU1 insert + load backfill.
--    Then the friend-country anti-join collapses from a 2-hop traversal
--      MATCH (friend)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(fCountry:Country)
--      WHERE fCountry.name <> $countryXName AND fCountry.name <> $countryYName
--    to a property check
--      WHERE friend.country_name <> $countryXName AND friend.country_name <> $countryYName
--    ~10-30 ms saved per call at SF1000.
--
-- 2. Denormalize msg.creationDate onto the IS_LOCATED_IN edge (mirrors the
--    Future Step #1 in interactive-complex-9.sql for HAS_CREATOR). Populate
--    at IU6/IU7 insert + load backfill, then add:
--      ALTER TABLE ldbc_snb."IS_LOCATED_IN" ADD COLUMN msg_creation_date bigint;
--      CREATE INDEX idx_islocatedin_end_creationdate
--        ON ldbc_snb."IS_LOCATED_IN" (end_id, msg_creation_date);
--    Lets `(country)<-[:IS_LOCATED_IN]-(msg) WHERE msg.creationDate ...` be
--    a tight composite-index slice instead of a probe-and-filter on every
--    Comment/Post vertex. ~1-5 s saved per call at SF1000 (the dominant
--    cost at scale).
--
-- 3. Pure-SQL pathway (drop-in replacement). When raw throughput at SF1000
--    matters more than Cypher fidelity, the form below skips cypher() entirely
--    and drives the message scan from the country-side IS_LOCATED_IN index
--    with a hash-set semi-join against the friend graphids. Measured at SF0.1:
--    ~65 ms (sample 1) / ~41 ms (sample 3) at the SQL level — ~2x faster than
--    the C8 Cypher form here. At SF1000 the win compounds because:
--      a) friend set is graphid-only (8 bytes each, ~80 KB at 10 K friends
--         vs C8's potential 5 MB agtype list when matches force the friend
--         tree to materialise),
--      b) join order is explicit — no AGE planner ambiguity around
--         `id(d) = did` becoming a Person seq-scan at scale, and
--      c) no cypher() per-call overhead (~100-150 ms saved per call).
--    Trade-off: loses Cypher readability. Prerequisites already in place:
--    idx_country_name, idx_islocatedin_end, idx_hascreator_start,
--    idx_*_graphid, idx_knows_start, idx_person_id (all in
--    scripts/create-indexes.sql).
--
--    Drop-in pure-SQL form (validated against the same 3 LDBC samples,
--    produces byte-identical results; output stays agtype-typed so the
--    existing Java handler in AgeDb.InteractiveQuery3 needs no change):
--
--    WITH params AS (
--      SELECT $personId::bigint        AS person_id_biz,
--             $startDate::bigint       AS start_date,
--             $endDate::bigint         AS end_date,
--             $countryXName::text      AS country_x,
--             $countryYName::text      AS country_y
--    ),
--    person AS (
--      SELECT p.id FROM ldbc_snb."Person" p, params
--      WHERE CAST(ag_catalog.agtype_object_field_text(p.properties,'id') AS bigint) = params.person_id_biz
--    ),
--    direct_knows AS (
--      SELECT k.end_id AS friend_id
--      FROM ldbc_snb."KNOWS" k JOIN person p ON k.start_id = p.id
--    ),
--    foaf AS (
--      SELECT DISTINCT k2.end_id AS friend_id
--      FROM direct_knows d JOIN ldbc_snb."KNOWS" k2 ON k2.start_id = d.friend_id
--      WHERE k2.end_id NOT IN (SELECT friend_id FROM direct_knows)
--        AND k2.end_id <> (SELECT id FROM person)
--    ),
--    all_friends AS (SELECT friend_id FROM direct_knows UNION SELECT friend_id FROM foaf),
--    valid_friends AS (
--      SELECT af.friend_id
--      FROM all_friends af
--      JOIN ldbc_snb."IS_LOCATED_IN" il ON il.start_id = af.friend_id
--      JOIN ldbc_snb."IS_PART_OF"    ip ON ip.start_id = il.end_id
--      JOIN ldbc_snb."Country"       fc ON fc.id        = ip.end_id
--      CROSS JOIN params
--      WHERE ag_catalog.agtype_object_field_text(fc.properties,'name') <> params.country_x
--        AND ag_catalog.agtype_object_field_text(fc.properties,'name') <> params.country_y
--    ),
--    target_countries AS (
--      SELECT c.id, ag_catalog.agtype_object_field_text(c.properties,'name') AS cname
--      FROM ldbc_snb."Country" c, params
--      WHERE ag_catalog.agtype_object_field_text(c.properties,'name')
--          IN (params.country_x, params.country_y)
--    ),
--    country_msgs AS (
--      SELECT hc.end_id AS author_id, tc.cname
--      FROM target_countries tc
--      JOIN ldbc_snb."IS_LOCATED_IN" il ON il.end_id   = tc.id
--      JOIN ldbc_snb."Comment"       msg ON msg.id    = il.start_id
--      JOIN ldbc_snb."HAS_CREATOR"   hc  ON hc.start_id = msg.id
--      CROSS JOIN params
--      WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties,'creationDate') AS bigint) >= params.start_date
--        AND CAST(ag_catalog.agtype_object_field_text(msg.properties,'creationDate') AS bigint) <  params.end_date
--        AND hc.end_id IN (SELECT friend_id FROM valid_friends)
--      UNION ALL
--      SELECT hc.end_id, tc.cname
--      FROM target_countries tc
--      JOIN ldbc_snb."IS_LOCATED_IN" il ON il.end_id   = tc.id
--      JOIN ldbc_snb."Post"          msg ON msg.id    = il.start_id
--      JOIN ldbc_snb."HAS_CREATOR"   hc  ON hc.start_id = msg.id
--      CROSS JOIN params
--      WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties,'creationDate') AS bigint) >= params.start_date
--        AND CAST(ag_catalog.agtype_object_field_text(msg.properties,'creationDate') AS bigint) <  params.end_date
--        AND hc.end_id IN (SELECT friend_id FROM valid_friends)
--    )
--    SELECT
--      ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"id"'::ag_catalog.agtype])         AS friendId,
--      ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"firstName"'::ag_catalog.agtype])  AS friendFirstName,
--      ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"lastName"'::ag_catalog.agtype])   AS friendLastName,
--      SUM(CASE WHEN cm.cname = (SELECT country_x FROM params) THEN 1 ELSE 0 END)::int AS xCount,
--      SUM(CASE WHEN cm.cname = (SELECT country_y FROM params) THEN 1 ELSE 0 END)::int AS yCount,
--      COUNT(*)::int AS xyCount
--    FROM country_msgs cm
--    JOIN ldbc_snb."Person" per ON per.id = cm.author_id
--    GROUP BY per.id, per.properties
--    HAVING SUM(CASE WHEN cm.cname = (SELECT country_x FROM params) THEN 1 ELSE 0 END) > 0
--       AND SUM(CASE WHEN cm.cname = (SELECT country_y FROM params) THEN 1 ELSE 0 END) > 0
--    ORDER BY xyCount DESC,
--             ag_catalog.agtype_object_field_text(per.properties,'id')::bigint ASC
--    LIMIT 20;
--
--    To deploy: replace the active C8 Cypher block above with this CTE; no
--    config or Java changes required (IC3 is already excluded from
--    age_parameterized_queries because the outer SQL references country
--    names; the same exclusion applies to the pure-SQL form).
--
-- 4. If we ever resolve AGE's per-call cypher() overhead (parser cache,
--    agtype boxing in the JDBC fetch path, etc.), this query benefits the
--    most: SQL execution measured at ~35 ms but wall time observed at ~800 ms.
--    The fixed-cost tax dominates. Worth a focused profiling session against
--    AGE 1.6 internals.
--
-- 5. Apply the same `collect(DISTINCT id(...))` pattern to IC9, IC2, IC5
--    if they show up in profiling at higher SFs — the friend-set sort cost
--    becomes the dominant CPU use case at SF1000 with full-vertex collect.
-- ----------------------------------------------------------------------------
