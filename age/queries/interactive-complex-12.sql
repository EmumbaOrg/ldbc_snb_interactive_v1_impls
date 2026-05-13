-- LdbcQuery12 — Expert search: friends' replies to posts tagged under a TagClass subtree.
-- Cypher-only (AGENTS.md): single Cypher call, three WITH-chained phases.
-- Phase 1: walk IS_SUBCLASS_OF* from root TagClass to all subclasses. IS_SUBCLASS_OF
--          is a tiny table (≤100 nodes, depth ≤6) so variable-length traversal is safe;
--          the §4 pathology only affects large edge tables like KNOWS.
-- Phase 2: collect valid Tag graphids whose HAS_TYPE edge lands in any valid class.
-- Phase 3: traverse KNOWS -> friend <- HAS_CREATOR <- comment -> REPLY_OF -> :Post ->
--          HAS_TAG -> tag; filter tag by valid set; aggregate per friend.
-- KNOWS directed (-[:KNOWS]->) per AGE-QUIRKS §11.
-- replyCount bound via WITH before RETURN to avoid AGE-QUIRKS §5 ORDER BY alias bug.
-- Only direct (single-hop) Comment -> Post replies counted — :Post label on REPLY_OF
-- target enforces this; replies to Comments are excluded.

SELECT * FROM cypher('$graphName', $$
    MATCH (tc:TagClass {name: $tagClassName})
    OPTIONAL MATCH (tc)<-[:IS_SUBCLASS_OF*1..]-(sub:TagClass)
    WITH id(tc) AS root_id, collect(DISTINCT id(sub)) AS sub_ids
    WITH sub_ids + [root_id] AS class_ids
    MATCH (tag:Tag)-[:HAS_TYPE]->(cls:TagClass)
    WHERE id(cls) IN class_ids
    WITH collect(DISTINCT id(tag)) AS valid_tag_ids
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(:Post)-[:HAS_TAG]->(tag:Tag)
    WHERE id(tag) IN valid_tag_ids
    WITH friend.id          AS personId,
         friend.firstName   AS personFirstName,
         friend.lastName    AS personLastName,
         collect(DISTINCT tag.name)   AS tagNames,
         count(DISTINCT comment)      AS replyCount
    RETURN personId, personFirstName, personLastName, tagNames, replyCount
    ORDER BY replyCount DESC, personId ASC
    LIMIT 20
$$) AS (
    personId        agtype,
    personFirstName agtype,
    personLastName  agtype,
    tagNames        agtype,
    replyCount      agtype
);
