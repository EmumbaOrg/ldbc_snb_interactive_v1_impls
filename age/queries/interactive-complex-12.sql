-- LdbcQuery12 — Expert search (V2 — iter-3 denorm + MATERIALIZED + agtype casts)
--
-- V1: hybrid Cypher (TagClass hierarchy + friends) + SQL edge-table JOINs.
--     SF3 mean 875 ms.
-- V2 review fixes:
--   1. Denorm columns: Comment.creator_id, Comment.reply_of_id,
--      Tag.tagclass_id, TagClass.subclass_of_id — two fewer edge-table JOINs.
--   2. ldbc_snb.* literal schema refs; explicit graphid casts on cross-type joins.
--   3. Result columns cast to ag_catalog.agtype for handler compatibility.
--   4. valid_tags AS MATERIALIZED — prevents planner from inlining into HAS_TAG
--      at SF1000 (valid_tags ≈ 50-200 rows vs HAS_TAG ≈ 240 M rows).
--   5. All $params kept inside cypher calls so parameterized mode works.

WITH RECURSIVE
valid_classes(class_id) AS (
    -- Base: resolve root TagClass by name via Cypher
    SELECT (tc_id::text)::ag_catalog.graphid AS class_id
    FROM cypher('$graphName', $$
        MATCH (tc:TagClass {name: $tagClassName})
        RETURN id(tc)
    $$) AS x(tc_id agtype)
    UNION ALL
    -- Recursive: walk subclasses via denormalized subclass_of_id
    SELECT tc.id
    FROM ldbc_snb."TagClass" tc
    JOIN valid_classes vc ON tc.subclass_of_id = vc.class_id
),
valid_tags AS MATERIALIZED (
    SELECT t.id AS tag_id,
           ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.properties, '"name"'::ag_catalog.agtype]) AS tag_name
    FROM ldbc_snb."Tag" t
    JOIN valid_classes vc ON t.tagclass_id = vc.class_id
),
friends AS (
    SELECT friend_vid, friend_id, friend_fn, friend_ln
    FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
        RETURN id(friend), friend.id, friend.firstName, friend.lastName
    $$) AS (friend_vid agtype, friend_id agtype, friend_fn agtype, friend_ln agtype)
),
friend_replies AS (
    SELECT f.friend_id, f.friend_fn, f.friend_ln,
           c.id AS comment_id, c.reply_of_id AS post_id
    FROM friends f
    JOIN ldbc_snb."Comment" c ON c.creator_id = (f.friend_vid::text)::ag_catalog.graphid
    JOIN ldbc_snb."Post" p ON p.id = c.reply_of_id
),
matched AS (
    SELECT fr.friend_id, fr.friend_fn, fr.friend_ln,
           fr.comment_id, vt.tag_name
    FROM friend_replies fr
    JOIN ldbc_snb."HAS_TAG" ht ON ht.start_id = fr.post_id
    JOIN valid_tags vt ON ht.end_id = vt.tag_id
)
SELECT
    friend_id AS personId,
    friend_fn AS personFirstName,
    friend_ln AS personLastName,
    ('[' || string_agg(DISTINCT '"' || (tag_name::text) || '"', ', ') || ']')::ag_catalog.agtype AS tagNames,
    count(DISTINCT comment_id)::text::ag_catalog.agtype AS replyCount
FROM matched
GROUP BY friend_id, friend_fn, friend_ln
ORDER BY count(DISTINCT comment_id) DESC, (friend_id)::text::bigint ASC
LIMIT 20;
