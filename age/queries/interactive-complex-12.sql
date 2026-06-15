-- LdbcQuery12 — Expert search: friends' replies to posts tagged under a TagClass subtree.
-- Hybrid H1: two Cypher calls connected via PostgreSQL CTEs. The graph traversal stays in
-- Cypher; the tag-ID filter, aggregation, and sort are handled by outer SQL as a Hash Semi
-- Join on plain bigint columns. This eliminates the agtype_in_operator linear scan bottleneck
-- (5,085 × 743K = 3.78B comparisons at SF3 for broad tag classes) and moves the GROUP BY
-- off AGE-reconstructed vertex blobs onto plain bigint/text columns.
--
-- First Cypher call — TagClass hierarchy + valid tag IDs (SF-invariant):
--   d1-d6 OPTIONAL MATCH ladder (variable-length [:IS_SUBCLASS_OF*] crashes AGE 1.6 — §9).
--   Returns one row per valid tag.id (LDBC business ID bigint). MATERIALIZED forces a single
--   evaluation; without it PG≥12 may inline and re-execute per outer row.
--   Uses tag.id (LDBC business ID), NOT id(tag) (AGE internal graphid) — different namespaces.
--
-- Second Cypher call — main traversal (scales with SF):
--   friends (idx_knows_start) → comments (idx_hascreator_end) →
--   post-replies (idx_replyof_start, :Post label filters Comment-to-Comment out) →
--   post tags (idx_hastag_start). Each hop in its own WITH (consecutive-reverse-arrow bug).
--   KNOWS directed (-[:KNOWS]->) per AGE-QUIRKS §11. No HAS_TYPE hop here — adding it would
--   flip HAS_TAG from Nested Loop + Index Scan to Hash Join (7.8s regression, Phase 7).
--   personId/replyCount bound in WITH before RETURN per AGE-QUIRKS §5.
--
-- Two Cypher call occurrences → JDBC handler writes two ? placeholders and binds the same
-- agtype JSON to both. Each Cypher block references only its own $paramName.
--
-- AGENTS.md §14 compliance: outer SQL touches only the two CTE result sets; no direct reads
-- of AGE-managed tables (ldbc_snb."Person", ldbc_snb."HAS_TAG", etc.).

WITH valid_tag_ids AS MATERIALIZED (
    SELECT (tid::text::bigint) AS tag_biz_id
    FROM cypher('$graphName', $$
        MATCH (base:TagClass {name: $tagClassName})
        OPTIONAL MATCH (d1:TagClass)-[:IS_SUBCLASS_OF]->(base)
        OPTIONAL MATCH (d2:TagClass)-[:IS_SUBCLASS_OF]->(d1)
        OPTIONAL MATCH (d3:TagClass)-[:IS_SUBCLASS_OF]->(d2)
        OPTIONAL MATCH (d4:TagClass)-[:IS_SUBCLASS_OF]->(d3)
        OPTIONAL MATCH (d5:TagClass)-[:IS_SUBCLASS_OF]->(d4)
        OPTIONAL MATCH (d6:TagClass)-[:IS_SUBCLASS_OF]->(d5)
        UNWIND [base.id, d1.id, d2.id, d3.id, d4.id, d5.id, d6.id] AS classId
        WITH classId WHERE classId IS NOT NULL
        WITH collect(DISTINCT classId) AS validClassIds
        MATCH (tc:TagClass)
        WHERE tc.id IN validClassIds
        WITH tc
        MATCH (tag:Tag)-[:HAS_TYPE]->(tc)
        RETURN tag.id AS tid
    $$) AS x(tid agtype)
),
traversal AS (
    SELECT
        (friend_id::text::bigint)               AS friend_biz_id,
        friend_fn::text                         AS friend_fn_t,
        friend_ln::text                         AS friend_ln_t,
        (comment_gid::text)::ag_catalog.graphid AS comment_gid_s,
        (tag_id::text::bigint)                  AS tag_biz_id,
        tag_name::text                          AS tag_name_t
    FROM cypher('$graphName', $$
        MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
        WITH friend
        MATCH (friend)<-[:HAS_CREATOR]-(comment:Comment)
        WITH friend, comment
        MATCH (comment)-[:REPLY_OF]->(post:Post)
        WITH friend, comment, post
        MATCH (post)-[:HAS_TAG]->(tag:Tag)
        RETURN friend.id, friend.firstName, friend.lastName,
               id(comment), tag.id, tag.name
    $$) AS x(
        friend_id   agtype,
        friend_fn   agtype,
        friend_ln   agtype,
        comment_gid agtype,
        tag_id      agtype,
        tag_name    agtype
    )
),
agg AS (
    SELECT
        t.friend_biz_id,
        t.friend_fn_t,
        t.friend_ln_t,
        COUNT(DISTINCT t.comment_gid_s)                                              AS reply_count,
        -- tag_name sort uses COLLATE "C" (codepoint order) to match LDBC oracle.
        -- en_US.UTF-8 default sorts punctuation (`_`, `-`) after letters; LDBC uses codepoint.
        -- See AGE-QUIRKS §14 + IC11 / IC4 precedents. The COLLATE must be applied to BOTH
        -- the DISTINCT argument expression and the ORDER BY expression — PG aggregate rules
        -- require those expressions to match when DISTINCT is used inside string_agg.
        '[' || string_agg(DISTINCT ('"' || t.tag_name_t || '"') COLLATE "C", ','
                          ORDER BY ('"' || t.tag_name_t || '"') COLLATE "C") || ']'  AS tag_names_json
    FROM traversal t
    WHERE EXISTS (SELECT 1 FROM valid_tag_ids v WHERE v.tag_biz_id = t.tag_biz_id)
    GROUP BY t.friend_biz_id, t.friend_fn_t, t.friend_ln_t
    ORDER BY reply_count DESC, t.friend_biz_id ASC
    LIMIT 20
)
SELECT
    friend_biz_id::ag_catalog.agtype                AS personId,
    ('"' || friend_fn_t || '"')::ag_catalog.agtype  AS personFirstName,
    ('"' || friend_ln_t || '"')::ag_catalog.agtype  AS personLastName,
    tag_names_json::ag_catalog.agtype               AS tagNames,
    reply_count::ag_catalog.agtype                  AS replyCount
FROM agg
ORDER BY reply_count DESC, friend_biz_id ASC;
