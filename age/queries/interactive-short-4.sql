-- LdbcShortQuery4MessageContent
--
-- Why this is raw SQL instead of cypher():
--   The original Cypher form below produced an optimal plan at the SQL level —
--   GIN-index lookups on Comment and Post via property containment, with the
--   outer LIMIT 1 short-circuiting the second branch when the first matched.
--   EXPLAIN ANALYZE on SF0.1 measured planning 0.45 ms / execution 0.29 ms.
--
--   Despite that, observed wall-time at SF0.1 was ~149 ms mean / ~423 ms p99 —
--   25–50x slower than peer short queries (IS1, IS3, IS5, IS6, IS7) which all
--   sit at 1–6 ms mean. Single-call psql executions confirmed the SQL plan was
--   not the bottleneck. The remaining ~148 ms is JDBC + AGE per-call overhead:
--   cypher() compilation, agtype boxing on returns, and AgeConverter.toStr's
--   6-pass escape-unwrap (\", \\, \/, \n, \r, \t) over up to ~2 KB of content.
--
--   The pure-SQL rewrite below sidesteps that overhead — same approach as SQ6
--   (interactive-short-6.sql), measured at planning 0.065 ms / execution
--   0.026 ms at the SQL level. It uses idx_comment_id and idx_post_id (functional
--   B-tree on the extracted id, already in scripts/create-indexes.sql), and the
--   outer LIMIT 1 still short-circuits the second Append child — Post branch
--   reports `(never executed)` in the plan when input is a Comment.
--
--   Output columns are wrapped via ag_catalog.agtype_access_operator (string
--   fields) and ::bigint::ag_catalog.agtype (creationDate) — the same agtype
--   shape Cypher RETURN produces — so AgeConverter.toLong / AgeConverter.toStr
--   in AgeDb.ShortQuery4MessageContent.toResult continue to work unchanged.
--
-- Original Cypher implementation, kept for reference:
-- ----------------------------------------------------------------------------
-- SELECT * FROM (
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (m:Comment {id: $messageId})
--     RETURN m.creationDate, coalesce(m.content, m.imageFile)
--   $$) AS (messageCreationDate agtype, messageContent agtype)
--   UNION ALL
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (m:Post {id: $messageId})
--     RETURN m.creationDate, coalesce(m.content, m.imageFile)
--   $$) AS (messageCreationDate agtype, messageContent agtype)
-- ) msg
-- LIMIT 1;
-- ----------------------------------------------------------------------------

SELECT *
FROM (
  SELECT
    ag_catalog.agtype_object_field_text(m.properties, 'creationDate')::bigint::ag_catalog.agtype  AS messageCreationDate,
    COALESCE(
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[m.properties, '"content"'::ag_catalog.agtype]),
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[m.properties, '"imageFile"'::ag_catalog.agtype])
    ) AS messageContent
  FROM ldbc_snb."Comment" m
  WHERE CAST(ag_catalog.agtype_object_field_text(m.properties, 'id') AS bigint) = $messageId
  UNION ALL
  SELECT
    ag_catalog.agtype_object_field_text(m.properties, 'creationDate')::bigint::ag_catalog.agtype,
    COALESCE(
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[m.properties, '"content"'::ag_catalog.agtype]),
      ag_catalog.agtype_access_operator(VARIADIC ARRAY[m.properties, '"imageFile"'::ag_catalog.agtype])
    )
  FROM ldbc_snb."Post" m
  WHERE CAST(ag_catalog.agtype_object_field_text(m.properties, 'id') AS bigint) = $messageId
) msg
LIMIT 1;
