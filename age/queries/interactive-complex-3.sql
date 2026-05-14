-- LdbcQuery3 — Friends and FoF with messages in two countries (xCount/yCount/xyCount).
-- Three-CTE hybrid following the IC5 UNION friend-set pattern.
--
-- CTE 1 (friends): single Cypher call using UNION of 1-hop + 2-hop KNOWS arms
--   (avoids UNWIND/OPTIONAL MATCH which generates a 922M-row sort plan).
--   Each arm applies the city->country filter inside Cypher (pure agtype comparisons,
--   no agtype-to-text cast in outer SQL). UNION deduplicates friends appearing via both
--   paths. Uses idx_knows_start for both arms and idx_islocatedin_start + idx_ispartof_start
--   for the city->country filter.
--
-- CTE 2 (msgs): country-driven traversal (Comment arm + Post arm via UNION ALL).
--   Two Cypher calls scan comments/posts in countryX/Y during the date window via
--   idx_islocatedin_end (country probe) → date filter → idx_hascreator_start (creator).
--   Country comparisons done inside Cypher (agtype vs agtype) — no cast bug.
--   Returns (creator_graphid, xc flag, yc flag) for the outer SQL Hash Join.
--
-- Outer SQL: Hash Join msgs x friends on graphid (O(msgs + friends) — both small),
--   GROUP BY / HAVING / ORDER on native SQL types, agtype wrap in final SELECT.
--
-- Three Cypher call occurrences -> JDBC handler binds the same agtype JSON to all three.
-- IC3 is in age_parameterized_queries (all params including country names inside JSON).

WITH friends AS MATERIALIZED (
    SELECT (friend_gid::text)::ag_catalog.graphid  AS friend_graphid,
           (fid::text::bigint)                      AS friend_biz_id,
           fn::text                                 AS friend_fn,
           ln::text                                 AS friend_ln
    FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})-[:KNOWS]->(f:Person)
        WHERE f.id <> $personId
        MATCH (f)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(c:Country)
        WHERE c.name <> $countryXName AND c.name <> $countryYName
        RETURN id(f) AS friend_gid, f.id AS fid, f.firstName AS fn, f.lastName AS ln
        UNION
        MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(f:Person)
        WHERE f.id <> $personId
        MATCH (f)-[:IS_LOCATED_IN]->(:City)-[:IS_PART_OF]->(c:Country)
        WHERE c.name <> $countryXName AND c.name <> $countryYName
        RETURN id(f) AS friend_gid, f.id AS fid, f.firstName AS fn, f.lastName AS ln
    $$) AS x(friend_gid agtype, fid agtype, fn agtype, ln agtype)
),
msgs AS MATERIALIZED (
    SELECT (creator_gid::text)::ag_catalog.graphid   AS creator_graphid,
           (xc::text::bigint)                         AS xc,
           (yc::text::bigint)                         AS yc
    FROM cypher('$graphName', $$
        MATCH (country:Country)
        WHERE country.name IN [$countryXName, $countryYName]
        WITH country
        MATCH (country)<-[:IS_LOCATED_IN]-(msg:Comment)
        WHERE msg.creationDate >= $startDate AND msg.creationDate < $endDate
        WITH country, msg
        MATCH (msg)-[:HAS_CREATOR]->(friend:Person)
        RETURN id(friend) AS creator_gid,
               CASE WHEN country.name = $countryXName THEN 1 ELSE 0 END AS xc,
               CASE WHEN country.name = $countryYName THEN 1 ELSE 0 END AS yc
    $$) AS x(creator_gid agtype, xc agtype, yc agtype)
    UNION ALL
    SELECT (creator_gid::text)::ag_catalog.graphid,
           (xc::text::bigint), (yc::text::bigint)
    FROM cypher('$graphName', $$
        MATCH (country:Country)
        WHERE country.name IN [$countryXName, $countryYName]
        WITH country
        MATCH (country)<-[:IS_LOCATED_IN]-(msg:Post)
        WHERE msg.creationDate >= $startDate AND msg.creationDate < $endDate
        WITH country, msg
        MATCH (msg)-[:HAS_CREATOR]->(friend:Person)
        RETURN id(friend) AS creator_gid,
               CASE WHEN country.name = $countryXName THEN 1 ELSE 0 END AS xc,
               CASE WHEN country.name = $countryYName THEN 1 ELSE 0 END AS yc
    $$) AS x(creator_gid agtype, xc agtype, yc agtype)
),
agg AS (
    SELECT f.friend_biz_id, f.friend_fn, f.friend_ln,
           SUM(m.xc)::int                  AS xCount,
           SUM(m.yc)::int                  AS yCount,
           (SUM(m.xc) + SUM(m.yc))::int    AS xyCount
    FROM msgs m
    JOIN friends f ON m.creator_graphid = f.friend_graphid
    GROUP BY f.friend_biz_id, f.friend_fn, f.friend_ln
    HAVING SUM(m.xc) > 0 AND SUM(m.yc) > 0
)
SELECT friend_biz_id::ag_catalog.agtype                   AS personId,
       ('"' || friend_fn || '"')::ag_catalog.agtype        AS personFirstName,
       ('"' || friend_ln || '"')::ag_catalog.agtype        AS personLastName,
       xCount::ag_catalog.agtype                           AS xCount,
       yCount::ag_catalog.agtype                           AS yCount,
       xyCount::ag_catalog.agtype                          AS xyCount
FROM agg
ORDER BY xyCount DESC, friend_biz_id ASC
LIMIT 20;
