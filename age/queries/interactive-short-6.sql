-- LdbcShortQuery6MessageForum — return the containing forum and moderator for a message.
--
-- CANONICAL VLE FORM (2026-06-01): rewritten from the prior pure-SQL RECURSIVE walk
-- to the natural variable-length-path Cypher form, to SURFACE the AGE VLE weakness
-- upstream (project goal: expose limitations, not hide them). See QUERY-REVIEW.md and
-- the VLE before/after experiment.
--
-- WARNING — this query CRASHES Apache AGE 1.6: ANY `*` variable-length path
-- (`-[:REPLY_OF*1..]->`) drops the backend into recovery mode (not merely slow) —
-- the untyped-intermediate seq-scan pathology + "Invalid number of attributes"
-- through denorm label tables (AGE-QUIRKS §4/§9). It is GATED on the incoming AGE
-- VLE fix. It MUST remain DISABLED (LdbcShortQuery6MessageForum_enable=false) in all
-- validate/benchmark properties on this build — enabling it crashes the shared
-- Postgres and aborts any concurrent run. "before" state = crash; "after" (post-fix)
-- is what the experiment measures.
--
-- Two arms (no polymorphic Message label, §3): a Post is its own root; a Comment
-- walks REPLY_OF up to its root Post. Forum + moderator via CONTAINER_OF/HAS_MODERATOR.

SELECT * FROM (
  -- Post arm: the message is itself the root contained in the forum.
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person) WHERE m.id = $messageId
    RETURN f.id, f.title, mod.id, mod.firstName, mod.lastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype,
          moderatorFirstName agtype, moderatorLastName agtype)
  UNION ALL
  -- Comment arm: walk REPLY_OF up to the root Post, then its containing Forum + moderator.
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Comment)-[:REPLY_OF*1..]->(root:Post)<-[:CONTAINER_OF]-(f:Forum)-[:HAS_MODERATOR]->(mod:Person) WHERE m.id = $messageId
    RETURN f.id, f.title, mod.id, mod.firstName, mod.lastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype,
          moderatorFirstName agtype, moderatorLastName agtype)
) result
LIMIT 1;
