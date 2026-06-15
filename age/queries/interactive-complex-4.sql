-- LdbcQuery4 — Tags appearing exclusively in the given date window on friends' posts.
-- Approach A: two Cypher calls split into in_window + pre_window MATERIALIZED CTEs.
-- Outer SQL NOT EXISTS hash anti-join on bigint tag_biz_id eliminates the agtype IN
-- operator linear scan; COLLATE "C" on tag_name_t gives code-point sort order matching
-- Neo4j Java String.compareTo() (dots and underscores sort before uppercase letters).
-- Two Cypher call occurrences → JDBC handler binds the same agtype JSON to both.
-- KNOWS directed per AGE-QUIRKS §11 (IU8 stores bidirectionally).

WITH in_window AS MATERIALIZED (
    SELECT (tag_id::text::bigint)        AS tag_biz_id,
           tag_name::text                AS tag_name_t,
           (post_id::text::bigint)       AS post_biz_id
    FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
        WITH friend
        MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
        WHERE post.creationDate >= $startDate AND post.creationDate < $endDate
        WITH post
        MATCH (post)-[:HAS_TAG]->(tag:Tag)
        RETURN post.id AS post_id, tag.id AS tag_id, tag.name AS tag_name
    $$) AS x(post_id agtype, tag_id agtype, tag_name agtype)
),
pre_window AS MATERIALIZED (
    SELECT DISTINCT (tag_id::text::bigint) AS tag_biz_id
    FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
        WITH friend
        MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
        WHERE post.creationDate < $startDate
        WITH post
        MATCH (post)-[:HAS_TAG]->(tag:Tag)
        RETURN tag.id AS tag_id
    $$) AS x(tag_id agtype)
),
agg AS (
    SELECT iw.tag_name_t,
           COUNT(DISTINCT iw.post_biz_id) AS post_count
    FROM in_window iw
    WHERE NOT EXISTS (SELECT 1 FROM pre_window pw WHERE pw.tag_biz_id = iw.tag_biz_id)
    GROUP BY iw.tag_name_t
    ORDER BY post_count DESC, iw.tag_name_t COLLATE "C" ASC
    LIMIT 10
)
SELECT ('"' || tag_name_t || '"')::ag_catalog.agtype AS tagName,
       post_count::ag_catalog.agtype                 AS postCount
FROM agg
ORDER BY post_count DESC, tag_name_t COLLATE "C" ASC;
