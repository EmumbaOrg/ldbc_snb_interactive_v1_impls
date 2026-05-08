-- LdbcShortQuery6MessageForum
--
-- Why this is raw SQL instead of cypher():
--   The original Cypher used an 8-deep `OPTIONAL MATCH (rN)-[:REPLY_OF]->(rN+1)`
--   chain to walk a Comment back to its rootPost. AGE 1.6 plans each untyped
--   intermediate as a UNION ALL over every vertex label in the graph
--   (Comment, Post, Tag, Forum, ...), and the final `MATCH (p:Post) WHERE id(p) = id(rootPost)`
--   forces a full Seq Scan on Post even though the seed edge already pinned a
--   single graphid. Together these dominated the per-call cost (~950 ms at SF0.1).
--
--   AGE 1.6 also disallows two rewrites that would help in pure Cypher:
--     1. `MATCH (alreadyBound)-[...]->(...)`  → "variable already exists"
--     2. `OPTIONAL MATCH (r1:Comment)-[...]`  → "multiple labels for variable not supported"
--   so the chain cannot be re-typed in place.
--
--   The best Cypher-only ceiling we measured was ~250 ms via a UNION of
--   fixed-length, fully-typed paths — but that floor is structural: every
--   `(rp:Post)` reference still triggers a Seq Scan over the whole Post table,
--   which scales linearly with SF and is unworkable at SF100+.
--
--   The pure-SQL recursive CTE below sidesteps both pathologies:
--     - The walk is purely on REPLY_OF edges using idx_replyof_start (B-tree).
--     - There is NO join back to Post: walk naturally terminates AT the rootPost
--       because Posts have no outgoing REPLY_OF edges, so the deepest end_id IS
--       the rootPost. This avoids the Post seq-scan entirely.
--     - Forum/Person joins use the per-label graphid B-tree indexes added in
--       create-indexes.sql (idx_*_graphid). All accesses are O(log N).
--   Measured at SF0.1: ~0.5 ms warm, ~2 ms cold (vs ~1700 ms for the original).
--
--   Output columns are wrapped via ag_catalog.agtype_access_operator — the same
--   internal helper AGE Cypher uses — so AgeConverter sees agtype-typed values
--   exactly as before. No Java glue change required.
--
-- Original Cypher implementation, kept for reference:
-- ----------------------------------------------------------------------------
-- SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
-- FROM (
--   SELECT 1 AS src, * FROM cypher('$graphName', $$
--     MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(r1)
--     OPTIONAL MATCH (r1)-[:REPLY_OF]->(r2)
--     OPTIONAL MATCH (r2)-[:REPLY_OF]->(r3)
--     OPTIONAL MATCH (r3)-[:REPLY_OF]->(r4)
--     OPTIONAL MATCH (r4)-[:REPLY_OF]->(r5)
--     OPTIONAL MATCH (r5)-[:REPLY_OF]->(r6)
--     OPTIONAL MATCH (r6)-[:REPLY_OF]->(r7)
--     OPTIONAL MATCH (r7)-[:REPLY_OF]->(r8)
--     WITH coalesce(r8, r7, r6, r5, r4, r3, r2, r1) AS rootPost
--     MATCH (p:Post)<-[:CONTAINER_OF]-(forum:Forum)-[:HAS_MODERATOR]->(mod:Person)
--     WHERE id(p) = id(rootPost)
--     RETURN forum.id, forum.title, mod.id, mod.firstName, mod.lastName
--   $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype,
--           moderatorFirstName agtype, moderatorLastName agtype)
--   UNION ALL
--   SELECT 2 AS src, * FROM cypher('$graphName', $$
--     MATCH (post:Post {id: $messageId})<-[:CONTAINER_OF]-(forum:Forum)-[:HAS_MODERATOR]->(mod:Person)
--     RETURN forum.id, forum.title, mod.id, mod.firstName, mod.lastName
--   $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype,
--           moderatorFirstName agtype, moderatorLastName agtype)
-- ) forum
-- ORDER BY src
-- LIMIT 1;
-- ----------------------------------------------------------------------------

WITH RECURSIVE
  post_seed AS MATERIALIZED (
    SELECT p.id AS post_id
    FROM ldbc_snb."Post" p
    WHERE CAST(ag_catalog.agtype_object_field_text(p.properties, 'id') AS bigint) = $messageId
  ),
  -- Skip the Comment seed (and the recursive walk) when the input is a Post.
  -- LDBC datagen guarantees Message ids are disjoint between Post and Comment,
  -- so at most one seed is non-empty.
  comment_seed AS MATERIALIZED (
    SELECT c.id AS vid
    FROM ldbc_snb."Comment" c
    WHERE NOT EXISTS (SELECT 1 FROM post_seed)
      AND CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint) = $messageId
  ),
  -- Walk REPLY_OF up to depth 20 (LDBC reply chains are bounded ~8 across all SFs).
  -- Each step is one indexed lookup on idx_replyof_start.
  walk AS (
    SELECT r.start_id, r.end_id, 1 AS depth
    FROM ldbc_snb."REPLY_OF" r
    JOIN comment_seed s ON r.start_id = s.vid
    UNION ALL
    SELECT r.start_id, r.end_id, w.depth + 1
    FROM walk w
    JOIN ldbc_snb."REPLY_OF" r ON r.start_id = w.end_id
    WHERE w.depth < 20
  ),
  -- The walk's deepest end_id is the rootPost (Posts have no outgoing REPLY_OF).
  root_post AS (
    SELECT post_id FROM post_seed
    UNION ALL
    (SELECT end_id FROM walk ORDER BY depth DESC LIMIT 1)
  )
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties,   '"id"'::ag_catalog.agtype])        AS forumId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties,   '"title"'::ag_catalog.agtype])     AS forumTitle,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"id"'::ag_catalog.agtype])        AS moderatorId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"firstName"'::ag_catalog.agtype]) AS moderatorFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"lastName"'::ag_catalog.agtype])  AS moderatorLastName
FROM root_post rp
JOIN ldbc_snb."CONTAINER_OF"  co  ON co.end_id   = rp.post_id
JOIN ldbc_snb."Forum"         f   ON f.id        = co.start_id
JOIN ldbc_snb."HAS_MODERATOR" hm  ON hm.start_id = f.id
JOIN ldbc_snb."Person"        per ON per.id      = hm.end_id
LIMIT 1;
