-- LdbcQuery10 — Similar persons (friends-of-friends with shared interests)
--
-- Why this Cypher form (V3): four cooperating reorderings collapse the
-- per-call execution from ~148 ms to ~29 ms at SF0.1 (5x at the SQL level)
-- without changing semantics. Phase F earlier moved this query from a
-- two-call hybrid (3422 ms) to a single parameterised AGE call (455 ms
-- benchmark mean / 853 ms p99). V3 builds on Phase F.
--
--   (1) Early `WITH DISTINCT p, friend` after the 2-hop KNOWS — the raw
--       2-hop produces ~2 184 (intermediate, friend) rows with
--       multiplicity. Deduping immediately collapses to ~39 unique
--       friends. Every downstream operator runs N times instead of NxM.
--
--   (2) Birth-month filter applied right after the DISTINCT (pre-direct,
--       pre-city). Surviving set drops to ~28 friends; everything below
--       pays per-friend cost on this small set.
--
--   (3) `OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)` runs after the
--       DISTINCT — once per unique friend instead of once per
--       (intermediate, friend) tuple. Same idx_knows_start path, fewer
--       loops.
--
--   (4) `MATCH (friend)-[:IS_LOCATED_IN]->(city:City)` deferred to AFTER
--       the birth-month filter. Only the ~28 surviving friends look up
--       their city via idx_islocatedin_start, not the full ~39 candidate
--       set.
--
--   (5) Single-pass `OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post)` plus
--       a chained `OPTIONAL MATCH (post)-[:HAS_TAG]->(t)<-[:HAS_INTEREST]-(p)`,
--       counting via `count(DISTINCT post)` and
--       `count(DISTINCT CASE WHEN t IS NOT NULL THEN post END)`. Same
--       semantics as the original two-pass form
--       (count(DISTINCT post) for postCount,
--        count(DISTINCT commonPost) for commonPostCount), with the post
--       row stream traversed once instead of twice. ~12 028 post lookups
--       collapsed to ~6 014.
--
-- The original Phase F form is preserved in git history (commit before
-- this change). Embedding the original literal block here as a comment
-- would corrupt AgeQueryStore.prepareTemplate's substitution count — see
-- the IC5 file's note on the same gotcha.
--
-- AGE 1.6 limitations encountered (and worked around):
--   - No label-OR predicates, so the per-post tag-existence check uses
--     CASE WHEN over the chained OPTIONAL MATCH instead of pattern
--     comprehension or EXISTS subquery (both either unsupported or
--     pathological in AGE 1.6 — see IC5 V9/V10 measurements).
--   - The OR predicate on (birthMonth, birthDay) prevents pushing into a
--     single property-containment MATCH; splitting into a 2-arm UNION
--     would re-introduce friend-set computation twice. Keeping the OR
--     post-traversal filter is the right trade-off given V3's small
--     post-DISTINCT candidate set.

SELECT * FROM cypher('$graphName', $$
  MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
  WHERE friend.id <> $personId
  // (1) Early DISTINCT before direct-check or city traversal.
  WITH DISTINCT p, friend
  // (2) Birth-month filter applied to small unique-friend set.
  WHERE ((friend.birthMonth = $month AND friend.birthDay >= 21)
      OR (friend.birthMonth = ($month % 12) + 1 AND friend.birthDay < 22))
  // (3) Direct-check runs once per unique friend.
  OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
  WITH p, friend, direct
  WHERE direct IS NULL
  // (4) City lookup deferred to surviving friends only.
  MATCH (friend)-[:IS_LOCATED_IN]->(city:City)
  // (5) Single HAS_CREATOR sweep with chained tag-interest existence check.
  OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
  OPTIONAL MATCH (post)-[:HAS_TAG]->(t:Tag)<-[:HAS_INTEREST]-(p)
  WITH friend, city, post, t
  WITH friend, city,
       count(DISTINCT post) AS postCount,
       count(DISTINCT CASE WHEN t IS NOT NULL THEN post END) AS commonPostCount
  WITH friend, city, commonPostCount - (postCount - commonPostCount) AS commonInterestScore
  RETURN friend.id, friend.firstName, friend.lastName,
         commonInterestScore, friend.gender, city.name
  ORDER BY commonInterestScore DESC, friend.id ASC
  LIMIT 10
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        commonInterestScore agtype, personGender agtype, personCityName agtype);

-- ----------------------------------------------------------------------------
-- Future optimization steps (queue when SF100+ benchmarks demand it):
--
-- 1. Denormalize `Person.post_count` onto the Person vertex (mirrors the
--    Phase F birthMonth/birthDay precomputation). Maintained at IU6
--    (AddPost) and IU1 (AddPerson) + load backfill. Replaces the
--    postCount OPTIONAL MATCH with a property read — saves ~50% of
--    per-call cost at SF1000 (where ~7 000 surviving friends each fetch
--    ~215 posts via idx_post_graphid for the count alone).
--
-- 2. Composite index `(HAS_CREATOR.end_id, post_id)` if we ever promote
--    post.id onto HAS_CREATOR.properties. Would let `count(post)` per
--    friend be an index-only scan instead of a per-post heap lookup.
--    Schema change at IU6 + load.
--
-- 3. AGE per-call call-site overhead — the SF0.1 SQL plan is ~30 ms but
--    benchmark wall time is ~455 ms, so ~420 ms is per-call overhead
--    (parser cache miss, agtype boxing, JDBC text-mode fetch). Same tax
--    that's been documented for SQ6 / IS4 / IC3 / IC5. Resolving this in
--    AGE 1.6 internals would unlock IC10 (and every other Cypher query)
--    further.
--
-- 4. Apply V3's `WITH DISTINCT` + late-traversal pattern to other 2-hop
--    KNOWS queries if profiling at SF100+ flags them — the friend-set
--    multiplicity collapse helps any query that fans out before
--    filtering down.
-- ----------------------------------------------------------------------------
