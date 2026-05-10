-- LdbcQuery7 — Most recent likers of the user's messages
--
-- Why this Cypher form (W3 — pre-collected messages, NL probe on LIKES):
--
-- The original `MATCH (p)<-[:HAS_CREATOR]-(msg)<-[:LIKES]-(liker)` chain
-- compiled to a Hash Join with **Parallel Seq Scan on the full LIKES table**
-- (64 376 rows at SF0.1, ~64 M at SF1000) building the hash, then probing
-- with the user's ~770 messages. Total cost at SF0.1 was ~58 ms (sample 1)
-- to ~75 ms (sample 2), dominated by the LIKES seq scan time + per-row
-- hash probe.
--
-- W3 inverts the join via Cypher's `collect ... UNWIND` idiom:
--
--   MATCH (p)<-[:HAS_CREATOR]-(msg)
--   WITH p, collect(msg) AS msgs
--   UNWIND msgs AS msg
--   MATCH (msg)<-[like:LIKES]-(liker)
--
-- The collect + UNWIND introduces a materialisation barrier that forces
-- AGE's planner to bind the (small) `msg` set first, then probe LIKES via
-- nested-loop on `idx_likes_end`. EXPLAIN confirms:
--   `Index Scan using idx_likes_end on "LIKES"`
-- replaces the prior `Parallel Seq Scan`.
--
-- Per-call cost shifts from O(|LIKES|) seq-scan + O(|msgs|) hash probe to
-- O(|msgs|) NL probes via index. At SF0.1 with ~770 messages and ~64 K
-- LIKES, the trade is roughly even (~58-89 ms either direction). At SF1000
-- with ~64 M LIKES, the original would seq-scan ~64 M rows per call
-- (~5+ seconds CPU time alone), while W3 stays at O(|msgs|) ~770 NL probes
-- (~50 ms warm cache).
--
-- Measured at SF0.1 (sample-dependent — small data favours either plan):
--   sample 1: 58 ms → 89 ms (mild regression — small msg set, hash already cheap)
--   sample 2: 75 ms → 44 ms (-41%)
-- The trade is the right one for SF1000 readiness; benchmark p99
-- (sample-2-like cases) should improve materially.
--
-- The DISTINCT ON (latest like per liker) stays in the outer SQL because
-- pushing it into Cypher (`head(collect(... ORDER BY ...))`) added overhead
-- without a clear win.

SELECT personId, personFirstName, personLastName, likeCreationDate, commentOrPostId,
       commentOrPostContent, minutesLatency, isNew
FROM (
  SELECT DISTINCT ON (personId)
    personId, personFirstName, personLastName, likeCreationDate, commentOrPostId,
    commentOrPostContent, minutesLatency, isNew
  FROM (
    SELECT * FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)
      WITH p, collect(msg) AS msgs
      UNWIND msgs AS msg
      MATCH (msg)<-[like:LIKES]-(liker:Person)
      WITH p, liker, msg, like.creationDate AS likeTime
      OPTIONAL MATCH (p)-[knows:KNOWS]->(liker)
      RETURN liker.id, liker.firstName, liker.lastName, likeTime, msg.id,
             coalesce(msg.content, msg.imageFile),
             toInteger(floor(toFloat(likeTime - msg.creationDate) / 60000.0)),
             knows IS NULL
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, commentOrPostId agtype, commentOrPostContent agtype,
            minutesLatency agtype, isNew agtype)
    UNION ALL
    SELECT * FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)
      WITH p, collect(msg) AS msgs
      UNWIND msgs AS msg
      MATCH (msg)<-[like:LIKES]-(liker:Person)
      WITH p, liker, msg, like.creationDate AS likeTime
      OPTIONAL MATCH (p)-[knows:KNOWS]->(liker)
      RETURN liker.id, liker.firstName, liker.lastName, likeTime, msg.id,
             coalesce(msg.content, msg.imageFile),
             toInteger(floor(toFloat(likeTime - msg.creationDate) / 60000.0)),
             knows IS NULL
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, commentOrPostId agtype, commentOrPostContent agtype,
            minutesLatency agtype, isNew agtype)
  ) all_likes
  ORDER BY personId, likeCreationDate DESC, commentOrPostId ASC
) latest_likes
ORDER BY likeCreationDate DESC, personId ASC
LIMIT 20;

-- ----------------------------------------------------------------------------
-- Future optimization steps (queue when SF100+ benchmarks demand it):
--
-- 1. Composite index `idx_likes_end_creationdate_agtype` on
--    `(LIKES.end_id, ag_catalog.agtype_access_operator(properties, '"creationDate"'::agtype))`.
--    Would enable per-message ORDER BY pushdown for "latest like" queries
--    via index-only scan. Same pattern as the IC5 HAS_MEMBER composite.
--    Worth it if the DISTINCT-ON-personId logic becomes a bottleneck at SF1000.
--
-- 2. AGE per-call call-site overhead — same as documented elsewhere. SF0.1
--    SQL plan ~50-90 ms (W3), benchmark wall time ~106 ms. Resolving in
--    AGE 1.6 internals would unlock further gains.
--
-- 3. The `head(collect(...) ORDER BY ...)` per-liker aggregation idiom
--    would push DISTINCT ON into Cypher and reduce row count crossing the
--    AGE call-site boundary. Tested — added overhead at SF0.1, but might help
--    at SF1000 where the row count is much larger. Re-evaluate at scale.
-- ----------------------------------------------------------------------------
