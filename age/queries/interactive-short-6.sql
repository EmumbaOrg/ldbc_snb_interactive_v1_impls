-- LdbcShortQuery6MessageForum (iter-1 — pure SQL, structural choice — see note below)
--
-- CLASSIFICATION NOTE (cypher-restore pass, 2026-05-11):
--   IS6 intentionally remains pure SQL. This is NOT an oversight — it is the
--   correct choice given AGE 1.6 pathologies. The reasoning:
--
--   1. THE GRAPH TRAVERSAL PART (REPLY_OF chain) IS ALREADY IN SQL.
--      The most "graph-like" piece of IS6 — walking a Comment back to its root
--      Post through a variable-depth REPLY_OF chain — MUST stay in SQL because
--      AGE 1.6 cannot plan variable-length paths efficiently (see AGE-QUIRKS §4,
--      §9). The pathology: each untyped intermediate is planned as a UNION ALL
--      over every vertex label, and the final `MATCH (p:Post)` triggers a full
--      Post seq-scan regardless of the seed. Measured at SF0.1: ~950 ms Cypher
--      vs ~0.5 ms SQL. At SF1000 the Post seq-scan would dominate. Structural.
--
--   2. THE TRAILING LOOKUP (Forum + HAS_MODERATOR + Person) IS NOT GRAPH TRAVERSAL.
--      After the SQL walk identifies the rootPost graphid, the remaining work is
--      3 indexed-JOIN dereferences on well-known, typed relationships. Moving
--      these into a cypher() call would:
--        (a) Add ~150 ms constant cypher() per-call overhead.
--        (b) Require scanning all (Post, Forum, Person) tuples and filtering by
--            rootPost graphid in SQL — wasteful at SF1000 (millions of tuples).
--        (c) Provide zero graph-identity benefit: looking up a forum by a known
--            graphid is not "graph traversal" any more than a B-tree join is.
--
--   CONCLUSION: IS6 is a "structurally pure-SQL" query, not a "fake-hybrid".
--   The graph traversal (REPLY_OF chain walk) is in SQL for AGE-documented
--   structural reasons. Adding cypher() for the trailing lookup would add
--   overhead with zero identity gain. Documented here to prevent future passes
--   from incorrectly converting this query.
--
-- Original Cypher implementation, kept for reference (measured ~950-1700 ms at SF0.1):
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
