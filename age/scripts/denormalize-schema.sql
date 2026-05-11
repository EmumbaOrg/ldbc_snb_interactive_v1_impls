-- Denormalisation schema (matches the LDBC postgres / umbra / duckdb reference impls).
--
-- The reference relational impls flatten all 1:1 outbound edges onto entity
-- tables and rely on direct indexed JOINs instead of edge traversals. AGE on
-- Postgres has the same cost model (relational planner under the graph layer)
-- without the denormalisation benefit unless we add it explicitly.
--
-- This file:
--   1. ALTERs each AGE-managed entity table to add denormalised graphid columns.
--   2. Backfills those columns from the existing edge tables (one INSERT-from-JOIN
--      per column, after data load).
--   3. Adds B-tree indexes on the new columns + composite indexes for hot
--      JOIN patterns (matching postgres/index_creatorid + index_forumid + etc.).
--
-- Run order:
--   - load-data.sh's existing Step 2 (agefreighter load) populates the edge tables.
--   - This script runs BETWEEN existing Step 3 (create-indexes) and Step 4 (vacuum).
--   - IU handler updates (interactive-update-{1,4,6,7}.sql) maintain the columns
--     on subsequent CREATEs during the benchmark.
--
-- Idempotent (IF NOT EXISTS / NULL-safe UPDATEs).

SET maintenance_work_mem = '4GB';
SET search_path = ldbc_snb, ag_catalog, public;

-- =========================================================================
-- 1. Add denormalised graphid columns to entity tables
-- =========================================================================

-- Post: HAS_CREATOR + CONTAINER_OF + IS_LOCATED_IN denorms
ALTER TABLE "Post"     ADD COLUMN IF NOT EXISTS creator_id    ag_catalog.graphid;
ALTER TABLE "Post"     ADD COLUMN IF NOT EXISTS forum_id      ag_catalog.graphid;
ALTER TABLE "Post"     ADD COLUMN IF NOT EXISTS country_id    ag_catalog.graphid;

-- Comment: HAS_CREATOR + REPLY_OF + IS_LOCATED_IN denorms
ALTER TABLE "Comment"  ADD COLUMN IF NOT EXISTS creator_id    ag_catalog.graphid;
ALTER TABLE "Comment"  ADD COLUMN IF NOT EXISTS reply_of_id   ag_catalog.graphid;
ALTER TABLE "Comment"  ADD COLUMN IF NOT EXISTS country_id    ag_catalog.graphid;

-- Forum: HAS_MODERATOR denorm
ALTER TABLE "Forum"    ADD COLUMN IF NOT EXISTS moderator_id  ag_catalog.graphid;

-- Person: IS_LOCATED_IN (→City) denorm
ALTER TABLE "Person"   ADD COLUMN IF NOT EXISTS city_id       ag_catalog.graphid;

-- Tag → TagClass via HAS_TYPE
ALTER TABLE "Tag"      ADD COLUMN IF NOT EXISTS tagclass_id   ag_catalog.graphid;

-- TagClass → parent TagClass via IS_SUBCLASS_OF (NULL for root)
ALTER TABLE "TagClass" ADD COLUMN IF NOT EXISTS subclass_of_id ag_catalog.graphid;

-- Place hierarchy via IS_PART_OF
ALTER TABLE "City"     ADD COLUMN IF NOT EXISTS country_id    ag_catalog.graphid;
ALTER TABLE "Country"  ADD COLUMN IF NOT EXISTS continent_id  ag_catalog.graphid;

-- Organisation locations via IS_LOCATED_IN
ALTER TABLE "University" ADD COLUMN IF NOT EXISTS city_id    ag_catalog.graphid;
ALTER TABLE "Company"    ADD COLUMN IF NOT EXISTS country_id ag_catalog.graphid;

-- =========================================================================
-- 2. Load-time backfill from edge tables
-- =========================================================================
-- Each denorm column is filled by joining the entity table to its corresponding
-- edge table (NULL-safe — preserves existing values if re-run on partial data).

-- Post.creator_id ← HAS_CREATOR (Post → Person)
UPDATE "Post" p
   SET creator_id = hc.end_id
  FROM "HAS_CREATOR" hc
 WHERE hc.start_id = p.id
   AND p.creator_id IS NULL;

-- Post.forum_id ← CONTAINER_OF (Forum → Post; need inverse)
UPDATE "Post" p
   SET forum_id = co.start_id
  FROM "CONTAINER_OF" co
 WHERE co.end_id = p.id
   AND p.forum_id IS NULL;

-- Post.country_id ← IS_LOCATED_IN (Post → Country)
UPDATE "Post" p
   SET country_id = il.end_id
  FROM "IS_LOCATED_IN" il
 WHERE il.start_id = p.id
   AND p.country_id IS NULL;

-- Comment.creator_id ← HAS_CREATOR (Comment → Person)
UPDATE "Comment" c
   SET creator_id = hc.end_id
  FROM "HAS_CREATOR" hc
 WHERE hc.start_id = c.id
   AND c.creator_id IS NULL;

-- Comment.reply_of_id ← REPLY_OF (Comment → Post|Comment)
UPDATE "Comment" c
   SET reply_of_id = ro.end_id
  FROM "REPLY_OF" ro
 WHERE ro.start_id = c.id
   AND c.reply_of_id IS NULL;

-- Comment.country_id ← IS_LOCATED_IN (Comment → Country)
UPDATE "Comment" c
   SET country_id = il.end_id
  FROM "IS_LOCATED_IN" il
 WHERE il.start_id = c.id
   AND c.country_id IS NULL;

-- Forum.moderator_id ← HAS_MODERATOR (Forum → Person)
UPDATE "Forum" f
   SET moderator_id = hm.end_id
  FROM "HAS_MODERATOR" hm
 WHERE hm.start_id = f.id
   AND f.moderator_id IS NULL;

-- Person.city_id ← IS_LOCATED_IN (Person → City)
UPDATE "Person" pr
   SET city_id = il.end_id
  FROM "IS_LOCATED_IN" il
 WHERE il.start_id = pr.id
   AND pr.city_id IS NULL;

-- Tag.tagclass_id ← HAS_TYPE (Tag → TagClass)
UPDATE "Tag" t
   SET tagclass_id = ht.end_id
  FROM "HAS_TYPE" ht
 WHERE ht.start_id = t.id
   AND t.tagclass_id IS NULL;

-- TagClass.subclass_of_id ← IS_SUBCLASS_OF (TagClass → TagClass)
UPDATE "TagClass" tc
   SET subclass_of_id = isc.end_id
  FROM "IS_SUBCLASS_OF" isc
 WHERE isc.start_id = tc.id
   AND tc.subclass_of_id IS NULL;

-- City.country_id ← IS_PART_OF (City → Country)
UPDATE "City" c
   SET country_id = ip.end_id
  FROM "IS_PART_OF" ip
 WHERE ip.start_id = c.id
   AND c.country_id IS NULL;

-- Country.continent_id ← IS_PART_OF (Country → Continent)
UPDATE "Country" co
   SET continent_id = ip.end_id
  FROM "IS_PART_OF" ip
 WHERE ip.start_id = co.id
   AND co.continent_id IS NULL;

-- University.city_id ← IS_LOCATED_IN (University → City)
UPDATE "University" u
   SET city_id = il.end_id
  FROM "IS_LOCATED_IN" il
 WHERE il.start_id = u.id
   AND u.city_id IS NULL;

-- Company.country_id ← IS_LOCATED_IN (Company → Country)
UPDATE "Company" co
   SET country_id = il.end_id
  FROM "IS_LOCATED_IN" il
 WHERE il.start_id = co.id
   AND co.country_id IS NULL;

-- =========================================================================
-- 3. Indexes on the new columns
-- =========================================================================
-- Single-column indexes for direct lookups, plus a few composites for the
-- hottest JOIN patterns (mirrors postgres ref's message_creatorid +
-- message_forumid + message_replyof + forum_moderatorid).

-- Post indexes (mirrors message_creatorid, message_forumid, message_locationid)
CREATE INDEX IF NOT EXISTS idx_post_creator_id   ON "Post" (creator_id);
CREATE INDEX IF NOT EXISTS idx_post_forum_id     ON "Post" (forum_id);
CREATE INDEX IF NOT EXISTS idx_post_country_id   ON "Post" (country_id);
-- Composite: IC5's `forum_id = X AND creator_id = Y` LEFT JOIN
CREATE INDEX IF NOT EXISTS idx_post_forum_creator ON "Post" (forum_id, creator_id);

-- Comment indexes (mirrors message_creatorid, message_replyof, message_locationid)
CREATE INDEX IF NOT EXISTS idx_comment_creator_id  ON "Comment" (creator_id);
CREATE INDEX IF NOT EXISTS idx_comment_reply_of_id ON "Comment" (reply_of_id);
CREATE INDEX IF NOT EXISTS idx_comment_country_id  ON "Comment" (country_id);

-- Forum
CREATE INDEX IF NOT EXISTS idx_forum_moderator_id  ON "Forum" (moderator_id);

-- Person
CREATE INDEX IF NOT EXISTS idx_person_city_id      ON "Person" (city_id);

-- Tag / TagClass / Place hierarchy
CREATE INDEX IF NOT EXISTS idx_tag_tagclass_id           ON "Tag" (tagclass_id);
CREATE INDEX IF NOT EXISTS idx_tagclass_subclass_of_id   ON "TagClass" (subclass_of_id);
CREATE INDEX IF NOT EXISTS idx_city_country_id           ON "City" (country_id);
CREATE INDEX IF NOT EXISTS idx_country_continent_id      ON "Country" (continent_id);
CREATE INDEX IF NOT EXISTS idx_university_city_id        ON "University" (city_id);
CREATE INDEX IF NOT EXISTS idx_company_country_id        ON "Company" (country_id);

-- =========================================================================
-- 4. Composite (creator_id, creationDate DESC) for per-friend top-K message
-- queries (IC2, IC8). This is the index that unblocks "20 most recent
-- messages by friend" patterns at SF1000.
-- =========================================================================
-- creationDate is on the Comment/Post properties (agtype). Use the agtype
-- expression form to match how AGE compiles the WHERE comment.creationDate predicate.
CREATE INDEX IF NOT EXISTS idx_post_creator_creationdate
    ON "Post" (creator_id, ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"creationDate"'::ag_catalog.agtype]) DESC);

CREATE INDEX IF NOT EXISTS idx_comment_creator_creationdate
    ON "Comment" (creator_id, ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"creationDate"'::ag_catalog.agtype]) DESC);

-- =========================================================================
-- 5. Iteration-2 aggregates (IC5 / IC10 SF1000 unblocks)
-- =========================================================================
-- Goes beyond column-level denorm into precomputed aggregates / covering
-- indexes. AGE 1.6 segfaults when its Cypher CREATE clause has to insert
-- into a label table that has columns AGE doesn't recognise (specifically
-- crashes on `int NOT NULL DEFAULT` and `graphid[]`). To avoid the
-- segfault, iter-2 keeps all aggregates in SIDE TABLES (not on AGE label
-- tables) plus a composite index on the existing HAS_INTEREST edge.

-- 5a. ForumMemberPostCount: precomputed count of posts each Person made in
-- each Forum. Replaces IC5's per-pair Post LEFT JOIN with a single index
-- lookup. Maintained at IU6 (AddPost: increment).
CREATE TABLE IF NOT EXISTS "ForumMemberPostCount" (
  forum_id   ag_catalog.graphid NOT NULL,
  member_id  ag_catalog.graphid NOT NULL,
  post_count int                NOT NULL DEFAULT 0,
  PRIMARY KEY (forum_id, member_id)
);
CREATE INDEX IF NOT EXISTS idx_fmpc_member ON "ForumMemberPostCount" (member_id);

-- 5b. PersonPostCount: 1 row per Person, total post_count. Side table
-- (NOT on the Person label) because AGE 1.6 cannot handle extra columns
-- with NOT NULL DEFAULT on its label tables — Cypher CREATE segfaults.
-- Maintained at IU6 (increment); load-time backfill from Post.creator_id.
CREATE TABLE IF NOT EXISTS "PersonPostCount" (
  person_id  ag_catalog.graphid PRIMARY KEY,
  post_count int                NOT NULL DEFAULT 0
);

-- 5c. Composite covering index on HAS_INTEREST(start_id, end_id) — replaces
-- the would-be Person.interest_tag_ids array. Lets the IC10 per-post
-- check `EXISTS (SELECT 1 FROM HAS_INTEREST WHERE start_id = p AND
-- end_id = t)` be a single tight index probe instead of a NL via
-- idx_hasinterest_start + filter.
CREATE INDEX IF NOT EXISTS idx_hasinterest_start_end
    ON "HAS_INTEREST" (start_id, end_id);

-- =========================================================================
-- 6. Iteration-2 backfills
-- =========================================================================

-- ForumMemberPostCount: aggregate from already-denormalised Post columns.
-- ON CONFLICT DO NOTHING makes this idempotent (re-runs don't double-count).
INSERT INTO "ForumMemberPostCount" (forum_id, member_id, post_count)
SELECT forum_id, creator_id, COUNT(*)::int
FROM "Post"
WHERE forum_id IS NOT NULL AND creator_id IS NOT NULL
GROUP BY forum_id, creator_id
ON CONFLICT (forum_id, member_id) DO NOTHING;

-- PersonPostCount: aggregate from Post.creator_id. Pre-populate every
-- Person (even those with 0 posts) so IU6 increment can use UPDATE.
INSERT INTO "PersonPostCount" (person_id, post_count)
SELECT id, 0 FROM "Person"
ON CONFLICT (person_id) DO NOTHING;

UPDATE "PersonPostCount" ppc
   SET post_count = sub.cnt
  FROM (
    SELECT creator_id, COUNT(*)::int AS cnt
    FROM "Post"
    WHERE creator_id IS NOT NULL
    GROUP BY creator_id
  ) sub
 WHERE ppc.person_id = sub.creator_id
   AND ppc.post_count = 0;

-- =========================================================================
-- 7. ANALYZE all touched tables
-- =========================================================================

ANALYZE "Post";
ANALYZE "Comment";
ANALYZE "Forum";
ANALYZE "Person";
ANALYZE "Tag";
ANALYZE "TagClass";
ANALYZE "City";
ANALYZE "Country";
ANALYZE "University";
ANALYZE "Company";
ANALYZE "ForumMemberPostCount";
ANALYZE "PersonPostCount";
ANALYZE "HAS_INTEREST";
ANALYZE "HAS_TAG";
