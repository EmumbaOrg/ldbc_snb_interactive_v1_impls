WITH valid_tags AS (
    SELECT tag_vid, tag_name
    FROM cypher('$graphName', $$
        MATCH (base:TagClass {name: $tagClassName})
        OPTIONAL MATCH (d1:TagClass)-[:IS_SUBCLASS_OF]->(base)
        OPTIONAL MATCH (d2:TagClass)-[:IS_SUBCLASS_OF]->(d1)
        OPTIONAL MATCH (d3:TagClass)-[:IS_SUBCLASS_OF]->(d2)
        OPTIONAL MATCH (d4:TagClass)-[:IS_SUBCLASS_OF]->(d3)
        OPTIONAL MATCH (d5:TagClass)-[:IS_SUBCLASS_OF]->(d4)
        OPTIONAL MATCH (d6:TagClass)-[:IS_SUBCLASS_OF]->(d5)
        UNWIND [id(base), id(d1), id(d2), id(d3), id(d4), id(d5), id(d6)] AS classId
        WITH classId WHERE classId IS NOT NULL
        WITH collect(DISTINCT classId) AS validIds
        MATCH (tag:Tag)-[:HAS_TYPE]->(tc:TagClass)
        WHERE id(tc) IN validIds
        RETURN id(tag), tag.name
    $$) AS (tag_vid agtype, tag_name agtype)
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
           hc.start_id AS comment_id, ro.end_id AS post_id
    FROM friends f
    JOIN $graphName."HAS_CREATOR" hc ON hc.end_id = f.friend_vid
    JOIN $graphName."REPLY_OF" ro ON ro.start_id = hc.start_id
    JOIN $graphName."Post" p ON p.id = ro.end_id
),
matched AS (
    SELECT fr.friend_id, fr.friend_fn, fr.friend_ln,
           fr.comment_id, vt.tag_name
    FROM friend_replies fr
    JOIN $graphName."HAS_TAG" ht ON ht.start_id = fr.post_id
    JOIN valid_tags vt ON ht.end_id = vt.tag_vid
)
SELECT
    friend_id AS personId,
    friend_fn AS personFirstName,
    friend_ln AS personLastName,
    '[' || string_agg(DISTINCT tag_name::text, ', ') || ']' AS tagNames,
    count(DISTINCT comment_id) AS replyCount
FROM matched
GROUP BY friend_id, friend_fn, friend_ln
ORDER BY count(DISTINCT comment_id) DESC, (friend_id)::text::bigint ASC
LIMIT 20;
