-- LdbcQuery10 — Similar persons (friends-of-friends with shared interests)
--
-- Why this Cypher form (V4 — collect+UNWIND barrier for SF3+ planner stability):
--
-- V3 had four cooperating reorderings (early WITH DISTINCT, deferred city,
-- single HAS_CREATOR walk with chained interest-tag check) that worked
-- beautifully at SF0.1: ~150 ms benchmark mean. At SF3 V3 catastrophically
-- regressed — single calls timing out at 120s, multi-thread stuck queries
-- running >1 hour.
--
-- Root cause at SF3: after the friend tree expands (~329-4900 surviving
-- friends after birth-month filter), AGE 1.6's planner stops choosing NL
-- via idx_islocatedin_start and instead picks a Merge Join over the full
-- IS_LOCATED_IN table (9M rows at SF3, would be 90M+ at SF1000). The
-- merge-join inner is `Index Scan using idx_islocatedin_end on
-- "IS_LOCATED_IN" rows=9042640` — effectively a full table scan masked
-- as an index scan. Same pathology then propagates to the
-- HAS_CREATOR / HAS_TAG joins downstream.
--
-- V4 inserts a `WITH p, collect(friend) AS friends UNWIND friends AS
-- friend` materialisation barrier between the direct-check and the
-- city/post traversals. This forces AGE's planner to:
--   (1) Materialise the small surviving friend set (a few hundred items).
--   (2) NL-iterate per friend through idx_islocatedin_start, idx_hascreator_end,
--       idx_hastag_start, idx_hasinterest_start.
--
-- Same pattern that won for IC7 W3 (post-binding NL via idx_likes_end)
-- and is the dual of the IC10 V3 pre-collect step that won at SF0.1.
--
-- Measured at SF3:
--   sample 1 (personId=4398046536251, month=4): V3 ~2 s → V4 ~2 s (no change)
--   sample 2 (personId=26388279087663, month=3, friend tree=4899→421):
--     V3 timed out at 120 s → V4 ~16.9 s (≥7× improvement, no longer pathological)
-- Same exact result rows on both samples.
--
-- SF1000 outlook: V4 stays index-driven NL throughout. Per-friend cost is
-- O(posts-per-friend × tags-per-post) bounded by indexes. At SF1000 with
-- ~3000 surviving friends × ~10 800 posts each, the bound is ~32 M post
-- probes (~30-60 sec). Past that scale, denormalising
-- `Person.post_count` and adding a side table for `Person.has_interest`
-- → tag-id list (or covering index on HAS_INTEREST.start_id) is the
-- next step.
--
-- Why not VLE: AGE 1.6 VLE compiles to wide hash join over per-depth
-- materialised paths — 5× slower than fixed-depth chains for shallow
-- patterns (per IC12 W2 measurements).

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
  // (4) collect+UNWIND barrier — forces planner to NL the downstream
  // traversals via idx_islocatedin_start / idx_hascreator_end. Without
  // this barrier, AGE 1.6 picks Merge Join on full IS_LOCATED_IN at
  // SF3+ (9M rows scanned per call → query times out).
  WITH p, collect(friend) AS friends
  UNWIND friends AS friend
  // (5) City lookup deferred to surviving friends only, NL-driven.
  MATCH (friend)-[:IS_LOCATED_IN]->(city:City)
  // (6) Single HAS_CREATOR sweep with chained tag-interest existence check.
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
-- Future optimization steps (queue when SF1000+ benchmarks demand it):
--
-- 1. Denormalize `Person.post_count` onto the Person vertex. Maintained
--    at IU6 (AddPost) and IU1 (AddPerson) + load backfill. Replaces the
--    HAS_CREATOR walk with a property read — saves ~50% of per-call cost
--    at SF1000.
--
-- 2. Composite index on HAS_INTEREST `(start_id, end_id)` (start_id is
--    Person, end_id is Tag). Lets the per-post tag-interest existence
--    check be a tight index probe instead of a hash lookup at large
--    person-interest cardinalities.
--
-- 3. Per-Person interest-tag list as denormalised property
--    `Person.interest_tag_ids` (array). The `<-[:HAS_INTEREST]-(p)` check
--    becomes `t.id IN p.interest_tag_ids`. Saves an index lookup per
--    candidate post.
--
-- 4. AGE per-call call-site overhead — same as documented elsewhere.
--
-- 5. AGE 1.7+ VLE planner improvements would let the 2-hop KNOWS chain
--    collapse to `(p)-[:KNOWS*2]->(friend)`. Re-evaluate when AGE
--    upgrades.
-- ----------------------------------------------------------------------------
