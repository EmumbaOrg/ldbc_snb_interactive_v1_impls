-- LdbcQuery5 — Recent groups via friends and friends-of-friends
--
-- Why this Cypher form (V7 — forum-driven OPTIONAL MATCH):
--   IC5 finds forums where a friend or friend-of-friend joined recently
--   (`member.joinDate > $minDate`), counts how many posts each such friend
--   wrote in that forum, dedupes per (friend, forum), then aggregates per
--   forum and returns the top-20 by post count.
--
--   Original implementation (kept commented at the bottom) used the post
--   pattern `(friend)<-[:HAS_CREATOR]-(post:Post)<-[:CONTAINER_OF]-(forum)`.
--   At SF0.1 it measured ~362–385 ms total (planning 9.9 ms, execution 385 ms).
--   The bottleneck is Branch 2 (FoFs after `WITH DISTINCT friend`) — AGE 1.6
--   compiles the OPTIONAL MATCH as a Hash Left Join over **full Post +
--   HAS_CREATOR + CONTAINER_OF tables** (Parallel Seq Scans on all three),
--   regardless of how few (friend, forum) pairs survive the upstream MATCH.
--   That parallel hash join dominates the cost and scales linearly with table
--   size — at SF1000 the same pattern would scan ~67 M Post rows per call.
--
--   V7 flips the post pattern to drive from the forum side:
--     OPTIONAL MATCH (forum)-[:CONTAINER_OF]->(post:Post)-[:HAS_CREATOR]->(friend)
--   With `forum` already bound, AGE's planner picks `idx_containerof_start`
--   to enumerate posts per forum (~9 posts on average), then verifies the
--   creator via `idx_hascreator_start` instead of building hash tables on
--   full Post/HAS_CREATOR/CONTAINER_OF. Measured: ~335 ms total at SF0.1
--   (~8% faster) with byte-identical results.
--
--   Variants tried and rejected:
--     - Single-call form with `collect(DISTINCT id(...))` + UNWIND + re-MATCH:
--         499 ms — re-MATCH on graphid degenerates into a Person seq scan.
--     - Single-call form with `collect(DISTINCT friend)` (vertex-based):
--         592 ms — `MATCH (friend2:Person) WHERE id(friend2)=id(fr)` adds a
--         per-friend Bitmap Heap Scan via gin_person.
--     - Drop `WITH DISTINCT friend` in branch 2: 417 ms but **wrong results**
--         — count(post) inflates because the same FoF can be reached via
--         multiple intermediate friends, and the row-stream multiplicity
--         feeds into count() before the outer `DISTINCT ON (friendId, forumId)`
--         dedup picks a representative.
--     - Pattern comprehension `size([(...)|...])`: AGE 1.6 syntax error.
--     - EXISTS subquery for post-existence: 2 570 ms — SubPlan executes
--         once per candidate row.
--
--   The Cypher form here was thought to be at a "structural ceiling"
--   bounded by AGE 1.6's parallel hash join on full Post for the post-
--   counting OPTIONAL MATCH. That diagnosis turned out to be wrong: the
--   ceiling was *index-shaped*, not Cypher-shaped. Adding a composite
--   index on HAS_MEMBER that matches AGE's compiled
--   `agtype_access_operator(VARIADIC ARRAY[properties, '"joinDate"'::agtype])`
--   expression (see scripts/create-indexes.sql, idx_hasmember_end_joindate_agtype)
--   lets the planner Bitmap Index Scan the upstream HAS_MEMBER set,
--   shrinking it enough that AGE flips the post-counting from the parallel
--   hash join to Nested Loop with `idx_containerof_start +
--   idx_hascreator_start + idx_post_graphid` — pure index access end-to-end.
--   Measured impact (V7 unchanged, just adding the index):
--     sample 1: 451 ms → 292 ms (-35%)
--     sample 2: 186 ms →  36 ms (-81%)
--   This is a generally-applicable AGE-on-Postgres pattern: indexing the
--   `agtype_access_operator(...)` expression directly (rather than a
--   `CAST(agtype_object_field_text(...) AS bigint)` form) is required for
--   AGE-compiled Cypher predicates to actually use the index.
--
-- Original implementation kept in git history (commit before this change).
-- The structural difference from the active V7 form below is the OPTIONAL
-- MATCH for posts — the original walked from the friend side via the
-- HAS_CREATOR edge, which AGE 1.6 compiled as a parallel hash join across
-- the full Post / HAS_CREATOR / CONTAINER_OF tables. Embedding the original
-- query body here as a comment block is unsafe because the literal
-- AgeQueryStore.prepareTemplate substitution counts call-site occurrences in
-- the raw string (including comments) and over-substitutes — see Future
-- Step #4 below for the underlying mechanism.

SELECT forumTitle, SUM(postCount::text::bigint)::int AS postCount
FROM (
  SELECT DISTINCT ON (friendId, forumId) friendId, forumId, forumTitle, postCount
  FROM (
    SELECT * FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)<-[member:HAS_MEMBER]-(forum:Forum)
      WHERE member.joinDate > $minDate AND friend.id <> $personId
      // V7: forum-driven post lookup uses idx_containerof_start to enumerate
      // posts per forum (~9 posts on average) then idx_hascreator_start to
      // verify creator, instead of a parallel hash join on full Post +
      // HAS_CREATOR + CONTAINER_OF tables.
      OPTIONAL MATCH (forum)-[:CONTAINER_OF]->(post:Post)-[:HAS_CREATOR]->(friend)
      RETURN friend.id, forum.id, forum.title, count(post)
    $$) AS (friendId agtype, forumId agtype, forumTitle agtype, postCount agtype)
    UNION ALL
    SELECT * FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
      WHERE friend.id <> $personId
      WITH DISTINCT friend
      MATCH (friend)<-[member:HAS_MEMBER]-(forum:Forum)
      WHERE member.joinDate > $minDate
      OPTIONAL MATCH (forum)-[:CONTAINER_OF]->(post:Post)-[:HAS_CREATOR]->(friend)
      RETURN friend.id, forum.id, forum.title, count(post)
    $$) AS (friendId agtype, forumId agtype, forumTitle agtype, postCount agtype)
  ) all_pairs
  ORDER BY friendId, forumId
) deduped
GROUP BY forumId, forumTitle
ORDER BY postCount DESC, forumId ASC
LIMIT 20;

-- ----------------------------------------------------------------------------
-- Future optimization steps (queue when SF100+ benchmarks demand it):
--
-- 1. Denormalize per-Person, per-Forum post count onto a maintained side
--    table. Mirrors the IC10 Phase F precomputation pattern. Would replace
--    the OPTIONAL MATCH for posts with a single property/table lookup.
--    Requires IU6 (AddPost) to update the count and load to backfill.
--    Significant work; only pay for it if SF1000 benchmarks demand.
--
-- 2. Composite index `(HAS_CREATOR.end_id, msg_container_id)` — if we ever
--    denormalise the container forum onto the HAS_CREATOR edge. Would let
--    the post-counting OPTIONAL MATCH be a tight index slice instead of a
--    Hash Left Join. Schema change at IU6/IU7 + load.
--
-- 3. Pure-SQL pathway (drop-in replacement). When raw throughput at SF1000
--    matters more than Cypher fidelity, the form below skips the AGE call
--    site for the bulk of the work and drives top-K from the friend × forum
--    pair side, then expands posts via idx_containerof_start + idx_hascreator_end.
--    Expected at SF0.1: ~50–80 ms (vs ~335 ms for the Cypher form here).
--    Sidesteps the parallel-hash-join-on-full-Post pathology entirely, plus
--    avoids the ~100–150 ms per-call AGE call-site overhead.
--
--    Drop-in pure-SQL form (validate before deploy with the same psql sanity
--    samples and the LDBC validator):
--
--    WITH params AS (
--      SELECT $personId::bigint AS person_id_biz,
--             $minDate::bigint  AS min_date
--    ),
--    person AS (
--      SELECT p.id FROM ldbc_snb."Person" p, params
--      WHERE CAST(ag_catalog.agtype_object_field_text(p.properties,'id') AS bigint) = params.person_id_biz
--    ),
--    direct_knows AS (
--      SELECT k.end_id AS friend_id
--      FROM ldbc_snb."KNOWS" k JOIN person p ON k.start_id = p.id
--    ),
--    foaf AS (
--      SELECT DISTINCT k2.end_id AS friend_id
--      FROM direct_knows d JOIN ldbc_snb."KNOWS" k2 ON k2.start_id = d.friend_id
--      WHERE k2.end_id NOT IN (SELECT friend_id FROM direct_knows)
--        AND k2.end_id <> (SELECT id FROM person)
--    ),
--    all_friends AS (SELECT friend_id FROM direct_knows UNION SELECT friend_id FROM foaf),
--    -- For each (friend, forum) where the friend joined the forum recently,
--    -- count posts the friend wrote that the forum contains.
--    pair_post_counts AS (
--      SELECT af.friend_id, m.start_id AS forum_gid,
--             COUNT(p.id) AS post_count
--      FROM all_friends af
--      JOIN ldbc_snb."HAS_MEMBER" m ON m.end_id = af.friend_id
--      CROSS JOIN params
--      WHERE CAST(ag_catalog.agtype_object_field_text(m.properties,'joinDate') AS bigint) > params.min_date
--      LEFT JOIN LATERAL (
--        SELECT p.id
--        FROM ldbc_snb."CONTAINER_OF" co
--        JOIN ldbc_snb."Post" p          ON p.id = co.end_id
--        JOIN ldbc_snb."HAS_CREATOR" hc  ON hc.start_id = p.id AND hc.end_id = af.friend_id
--        WHERE co.start_id = m.start_id
--      ) p ON TRUE
--      GROUP BY af.friend_id, m.start_id
--    )
--    SELECT
--      ag_catalog.agtype_access_operator(VARIADIC ARRAY[f.properties, '"title"'::ag_catalog.agtype]) AS forumTitle,
--      SUM(ppc.post_count)::int AS postCount
--    FROM pair_post_counts ppc
--    JOIN ldbc_snb."Forum" f ON f.id = ppc.forum_gid
--    GROUP BY ppc.forum_gid, f.properties
--    ORDER BY postCount DESC, ppc.forum_gid ASC
--    LIMIT 20;
--
--    Note: PostgreSQL syntax above mixes `JOIN` and `LEFT JOIN LATERAL` —
--    needs the JOINs reordered into a single FROM clause when actually
--    deployed. Spelled here for documentation.
--
-- 4. AGE per-call call-site overhead — the SF0.1 SQL plan was ~335 ms but
--    benchmark wall time was ~761 ms, so ~400 ms is per-call overhead
--    (parser cache miss, agtype boxing, JDBC text-mode fetch). Same tax
--    SQ6 / IS4 measured. Resolving this in AGE 1.6 internals would unlock
--    every Cypher query, not just IC5.
--
-- 5. Apply V7 (`(forum)-[:CONTAINER_OF]->(post:Post)-[:HAS_CREATOR]->(friend)`)
--    pattern flip to other queries with similar OPTIONAL MATCH shapes if
--    profiling shows them at SF100+.
-- ----------------------------------------------------------------------------
