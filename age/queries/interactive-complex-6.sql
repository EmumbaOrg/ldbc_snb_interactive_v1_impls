-- LdbcQuery6 — Tag co-occurrence among friends and friends-of-friends
--
-- Why this Cypher form (W5 — target-driven, explicit WITH boundaries):
--
-- IC6 finds tags that co-occur on posts written by the user's friends and
-- friends-of-friends, where the post is also tagged with the given tag.
-- The previous V5 form drove the leading MATCH from the friend tree
-- (`(p)-[:KNOWS]->(friend)<-[:HAS_CREATOR]-(post)-[:HAS_TAG]->(target)`)
-- and counted ~22,500 candidate friend × post × tag rows at SF0.1 before
-- the GROUP BY. W5 inverts the join order to drive from the (small) target
-- tag, then verifies each post's creator is a friend or FoF.
--
--   (1) `MATCH (target:Tag {name: $tagName})` — uses gin_tag, returns 1
--       Tag vertex. Same as V5.
--
--   (2) `MATCH (post:Post)-[:HAS_TAG]->(target)` — uses idx_hastag_end on
--       the bound `target` graphid. At SF0.1 there are ~30 posts tagged
--       with a typical given tag, so the entire downstream cost is
--       bounded by ~30 candidate posts.
--
--   (3) `MATCH (post)-[:HAS_CREATOR]->(creator:Person)` — uses
--       idx_hascreator_start (single row per post). Cheap.
--
--   (4) `MATCH (creator)<-[:KNOWS]-(p:Person {id: $personId})` (direct
--       branch) or via 2-hop with direct exclusion (FoF branch) — verifies
--       creator is reachable from the user. ~30 small KNOWS lookups via
--       idx_knows_end. Vs V5 first computing the full ~344-friend FoF set
--       and then iterating posts per friend.
--
--   Net work shift: O(friends × posts × tags) → O(target_posts × creator_check
--   + target_posts × tags). Measured at SF0.1: 138 ms → 39 ms (sample 1,
--   -72%); 141 ms → 15 ms (sample 2, -89%). Byte-identical results.
--
-- AGE 1.6 chained-reverse-arrow bug (worked around with explicit WITH):
--
--   Combining two consecutive reverse-arrow relationships in a single MATCH
--   clause silently returns 0 rows in AGE 1.6. The compiler appears to
--   miscompile the chain. The form below uses an explicit `WITH` between
--   each MATCH segment to break the chain into single-relationship steps:
--
--     -- Returns 0 (BROKEN in AGE 1.6):
--     -- MATCH (target:Tag {name: $tagName})<-[:HAS_TAG]-(post:Post)<-[:HAS_CREATOR]-(creator:Person)
--
--     -- Returns correct count (works):
--     -- MATCH (target:Tag {name: $tagName})
--     -- WITH target
--     -- MATCH (post:Post)-[:HAS_TAG]->(target)
--     -- WITH post, target
--     -- MATCH (post)-[:HAS_CREATOR]->(creator:Person)
--
--   Don't "simplify" the WITH boundaries away in this file — it'll break
--   correctness silently. Worth filing upstream and checking other queries
--   for the same pattern.
--
-- Variants tried and rejected:
--   - V1: `friend IN all_friends` (vertex agtype list): returned 0 rows.
--       AGE 1.6 vertex-equality semantics in IN predicates are unreliable.
--   - V2: `id(friend) IN all_friend_ids` (graphid list): same 0-row result.
--   - W1, W3: target-driven but without explicit WITH between MATCHes —
--       returned 0 rows due to the AGE bug above.
--
-- See create-indexes.sql for the agtype-expression-matching index pattern
-- used elsewhere; IC6 didn't need a new index since W5's hot path already
-- uses idx_hastag_end + idx_hascreator_start + idx_knows_end + gin_tag +
-- gin_person via property-containment MATCH.

SELECT tagName, SUM(postCount::text::bigint)::bigint AS postCount FROM (
  -- Branch 1 (direct friends)
  SELECT * FROM cypher('$graphName', $$
    MATCH (target:Tag {name: $tagName})
    WITH target
    MATCH (post:Post)-[:HAS_TAG]->(target)
    WITH post, target
    MATCH (post)-[:HAS_CREATOR]->(creator:Person)
    WITH post, target, creator
    MATCH (creator)<-[:KNOWS]-(p:Person {id: $personId})
    WITH post, target
    MATCH (post)-[:HAS_TAG]->(tag:Tag)
    WHERE tag <> target
    WITH tag.name AS tagName, count(DISTINCT post) AS postCount
    RETURN tagName, postCount
    ORDER BY postCount DESC, tagName ASC
  $$) AS (tagName agtype, postCount agtype)
  UNION ALL
  -- Branch 2 (friends-of-friends, excluding direct)
  SELECT * FROM cypher('$graphName', $$
    MATCH (target:Tag {name: $tagName})
    WITH target
    MATCH (post:Post)-[:HAS_TAG]->(target)
    WITH post, target
    MATCH (post)-[:HAS_CREATOR]->(creator:Person)
    WHERE creator.id <> $personId
    WITH post, target, creator
    MATCH (creator)<-[:KNOWS]-(:Person)<-[:KNOWS]-(p:Person {id: $personId})
    WITH DISTINCT post, target, creator, p
    OPTIONAL MATCH (p)-[direct:KNOWS]->(creator)
    WITH post, target, direct
    WHERE direct IS NULL
    MATCH (post)-[:HAS_TAG]->(tag:Tag)
    WHERE tag <> target
    WITH tag.name AS tagName, count(DISTINCT post) AS postCount
    RETURN tagName, postCount
    ORDER BY postCount DESC, tagName ASC
  $$) AS (tagName agtype, postCount agtype)
) tags
GROUP BY tagName
ORDER BY SUM(postCount::text::bigint) DESC, tagName::text COLLATE "C" ASC
LIMIT 10;

-- ----------------------------------------------------------------------------
-- Future optimization steps (queue when SF100+ benchmarks demand it):
--
-- 1. Denormalise tag co-occurrence at IU6 (AddPost) time. Maintain a
--    side table `tag_pair_post(tag_a, tag_b, post_id)` populated when a
--    post is created with multiple tags. Then IC6 collapses to a single
--    indexed read on `(tag_a = $tagName, friend IN all_friends)`. ~10x
--    saved per call at SF1000. Touches IU6 + load.
--
-- 2. AGE per-call call-site overhead — same as documented for IC3, IC5,
--    IC10. SF0.1 SQL plan ~39 ms (W5), observed wall time ~294 ms (V5),
--    so ~150-250 ms is per-call overhead. Resolving this in AGE 1.6
--    internals would unlock further gains.
--
-- 3. AGE 1.6 vertex-IN bug — `friend IN [collected_vertex_list]` returns
--    0 hits even when the list is correctly populated. If fixed upstream,
--    the single-call unified form would beat the 2-branch UNION ALL by
--    another 20-30%.
--
-- 4. AGE 1.6 chained-reverse-arrow bug — see header. Worth filing
--    upstream. Until fixed, ALL multi-segment patterns with consecutive
--    reverse arrows must use explicit WITH boundaries.
--
-- 5. Apply this W5 pattern (drive from a small selective vertex,
--    explicit WITH between MATCHes) to other "hub-and-spoke" Cypher
--    queries if profiling at SF100+ flags them.
-- ----------------------------------------------------------------------------
