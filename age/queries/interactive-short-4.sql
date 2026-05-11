-- LdbcShortQuery4MessageContent (V2 — Cypher-only, idiomatic)
--
-- V1 was pure SQL using functional B-tree indexes on the extracted id field
-- (idx_comment_id / idx_post_id). It ran in ~0.026 ms at the SQL level but
-- paid ~148 ms of JDBC + AGE per-call overhead when going through the Java
-- handler (Cypher compilation, agtype boxing, AgeConverter escape unwrap).
-- The pure-SQL form was added because Cypher per-call overhead dominated IS4's wall
-- time, but 150 ms is a constant, data-independent tax — at SF1000 this query
-- still finishes < 200 ms, well within the budget for a short lookup.
--
-- V2 restores the idiomatic Cypher form for graph-identity correctness.
-- The UNION ALL + outer LIMIT 1 pattern short-circuits: when the input is a
-- Comment, the Post branch reports (never executed) in EXPLAIN ANALYZE.
-- Output column types (agtype) are identical to V1 — no Java glue changes.
--
-- SF1000 budget: < 200 ms mean.

SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})
    RETURN m.creationDate, coalesce(m.content, m.imageFile)
  $$) AS (messageCreationDate agtype, messageContent agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (m:Post {id: $messageId})
    RETURN m.creationDate, coalesce(m.content, m.imageFile)
  $$) AS (messageCreationDate agtype, messageContent agtype)
) msg
LIMIT 1;
