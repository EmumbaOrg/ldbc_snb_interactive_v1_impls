-- LdbcQuery12 — Friends who replied on posts tagged with descendants of a TagClass
--
-- Why this Cypher form (W2 — pre-collected descendants):
--
-- IC12 finds friends who wrote replies (Comments via REPLY_OF) on posts whose
-- tags belong to the given TagClass or any of its descendants. The original
-- form walked the IS_SUBCLASS_OF hierarchy with 6 stacked OPTIONAL MATCH
-- clauses *per (friend, reply, tag, tc) row*, then applied a 7-way OR check
-- to test reachability. With ~6,000 candidate rows at SF0.1, that meant
-- ~36,000 OPTIONAL MATCH executions plus a wide row carrying (s1..s6) agtype
-- columns through the WITH boundary.
--
-- W2 inverts the hierarchy walk:
--
--   (1) Pin `base:TagClass` once via gin_tagclass.
--
--   (2) Pre-collect the descendants of base into a list of graphids using
--       a 6-level fixed-depth OPTIONAL MATCH chain on `(d:TagClass)-[:IS_SUBCLASS_OF]->(parent)`.
--       Runs ONCE on the small TagClass tree (76 vertices, max depth 5 in
--       LDBC) — total cost ~5 ms.
--
--   (3) Drive the friend tree as before (KNOWS → HAS_CREATOR → REPLY_OF →
--       HAS_TAG → HAS_TYPE), then check `id(tc) IN desc_ids` per row. The
--       check is a small-list membership test (~10-20 ids), much cheaper
--       than 6 stacked OPTIONAL MATCHes + 7-way OR.
--
-- Why VLE didn't work: `MATCH (descendant)-[:IS_SUBCLASS_OF*0..6]->(base)`
-- in AGE 1.6 was 5x SLOWER than the original (770 ms vs 150 ms). AGE's
-- variable-length expansion compiles to a wide hash join over per-depth
-- materialised paths, paying for every depth even when the actual tree is
-- shallow. The fixed-depth OPTIONAL MATCH chain avoids that overhead.
--
-- Measured impact at SF0.1:
--   sample 1 (BasketballPlayer): 149 ms → 70 ms (-53%)
--   sample 2 (Chancellor):       152 ms → 23 ms (-85%)
-- Same exact result rows on both samples.
--
-- SF1000 scaling note:
--
-- The hot per-row work (OPTIONAL MATCH + 7-way OR) was ~50 microseconds in
-- the original. At SF0.1 the candidate count is ~6,000 rows; at SF1000 it
-- scales to ~6 million rows. The original would spend ~5 minutes on the
-- per-row TagClass walk alone at SF1000. W2's `id(tc) IN desc_ids` check
-- is a constant ~5 microseconds per row — at SF1000 that's ~30 seconds for
-- the same row count. Order-of-magnitude better at scale.

SELECT * FROM cypher('$graphName', $$
  // (1) + (2) Pre-collect descendant TagClass ids of base.
  MATCH (base:TagClass {name: $tagClassName})
  WITH base
  OPTIONAL MATCH (d1:TagClass)-[:IS_SUBCLASS_OF]->(base)
  OPTIONAL MATCH (d2:TagClass)-[:IS_SUBCLASS_OF]->(d1)
  OPTIONAL MATCH (d3:TagClass)-[:IS_SUBCLASS_OF]->(d2)
  OPTIONAL MATCH (d4:TagClass)-[:IS_SUBCLASS_OF]->(d3)
  OPTIONAL MATCH (d5:TagClass)-[:IS_SUBCLASS_OF]->(d4)
  OPTIONAL MATCH (d6:TagClass)-[:IS_SUBCLASS_OF]->(d5)
  WITH collect(DISTINCT id(base))
       + collect(DISTINCT id(d1))
       + collect(DISTINCT id(d2))
       + collect(DISTINCT id(d3))
       + collect(DISTINCT id(d4))
       + collect(DISTINCT id(d5))
       + collect(DISTINCT id(d6)) AS desc_ids

  // (3) Friend → reply → post → tag → tc, filter by descendant set.
  MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
  MATCH (friend)<-[:HAS_CREATOR]-(reply:Comment)-[:REPLY_OF]->(post:Post)
  MATCH (post)-[:HAS_TAG]->(tag:Tag)-[:HAS_TYPE]->(tc:TagClass)
  WHERE id(tc) IN desc_ids
  WITH friend, collect(DISTINCT tag.name) AS tagNames, count(DISTINCT reply) AS replyCount
  RETURN friend.id, friend.firstName, friend.lastName, tagNames, replyCount
  ORDER BY replyCount DESC, toInteger(friend.id) ASC
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        tagNames agtype, replyCount agtype)
LIMIT 20;

-- ----------------------------------------------------------------------------
-- Future optimization steps (queue when SF100+ benchmarks demand it):
--
-- 1. Denormalise TagClass transitive closure as a materialised side table
--    `tagclass_descendants(ancestor_id graphid, descendant_id graphid)`
--    populated at load (TagClass tree is tiny and static — no IU updates).
--    Then IC12 collapses the descendant collection (steps 1-2) to a single
--    indexed lookup, saving ~5 ms per call. Probably not worth the schema
--    change since the savings are small relative to the friend-tree cost.
--
-- 2. AGE per-call call-site overhead — same as documented elsewhere. SF0.1
--    SQL plan ~50 ms (W2), benchmark wall time ~200 ms; ~150 ms is per-call
--    overhead. Resolving in AGE 1.6 internals would unlock more here.
--
-- 3. AGE 1.6 VLE (`[:REL*lower..upper]`) is much slower than fixed-depth
--    OPTIONAL MATCH chains for shallow hierarchies. Worth re-checking if
--    AGE upgrades fix the VLE planner — would let us collapse the 6-level
--    descendant collection into a one-line VLE.
--
-- 4. Apply this "pre-collect target set, then filter" pattern to other
--    queries with hierarchical OR chains if they show up in profiling.
-- ----------------------------------------------------------------------------
