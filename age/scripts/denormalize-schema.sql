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
-- Only ONE live denorm column remains: Post.creator_id (read by IC10).
-- All other label-table denorm columns are retired — no runtime IC/IS/IU
-- query reads them. Tier 3 cleanup (2026-05-15) removed the ALTER TABLE
-- statements so fresh loads no longer create them.
--
-- Retired column inventory (NOT created on fresh loads after 2026-05-15):
--   Post:        forum_id, country_id
--   Comment:     creator_id, reply_of_id, country_id
--   Forum:       moderator_id
--   Person:      city_id
--   Tag:         tagclass_id          (IC12 traverses HAS_TYPE via Cypher)
--   TagClass:    subclass_of_id        (IC12 traverses IS_SUBCLASS_OF via Cypher)
--   City:        country_id
--   Country:     continent_id
--   University:  city_id
--   Company:     country_id
--
-- For existing deployments where these columns were previously created:
-- AGE 1.6 blocks `ALTER TABLE ... DROP COLUMN` on label tables with
-- "table X is for label X". The columns persist as NULL and are inert;
-- they cannot be physically dropped until AGE 1.7+ relaxes this guard
-- (or via a full graph rebuild). Tier-3 migration
-- `migrations/2026-05-15-tier3-drop-unused-indexes.sql` drops the matching
-- indexes (which IS allowed by AGE 1.6).

ALTER TABLE "Post" ADD COLUMN IF NOT EXISTS creator_id ag_catalog.graphid;

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

-- Post.forum_id retired 2026-05-14: IU6 now sources forum/author gids from
-- Cypher RETURN; no external reader existed.
-- Post.country_id retired 2026-05-14: no read consumers.

-- Comment.creator_id and Comment.reply_of_id retired 2026-05-14: no read
-- consumers remain. UPDATE statements removed; columns stay on disk as NULL
-- (AGE 1.6 blocks DROP COLUMN on label tables). Indexes dropped by migration
-- 2026-05-14-retire-comment-creator-replyof.sql.

-- Comment.country_id, Forum.moderator_id, Person.city_id retired 2026-05-14:
-- no read consumers. Comment.country_id alone took ~10 min at SF3 on the
-- 6.4M-row Comment table; the saving compounds at SF10+.

-- Tag.tagclass_id + TagClass.subclass_of_id backfills retired 2026-05-15
-- (Tier 3). IC12 (the only consumer that previously read these) was migrated
-- to traverse `HAS_TYPE` / `IS_SUBCLASS_OF` via Cypher directly. No runtime
-- query reads these denorm columns. The ALTER TABLE ADD COLUMN statements
-- are also removed (section 1) so fresh loads don't create them. Existing
-- deployments retain the columns as NULL (AGE 1.6 blocks DROP COLUMN); the
-- matching indexes are dropped by
-- `migrations/2026-05-15-tier3-drop-unused-indexes.sql`.

-- Geographic hierarchy denorm columns (City.country_id, Country.continent_id,
-- University.city_id, Company.country_id) retired 2026-05-14: no read consumers
-- in any IC/IS/IU query. Tables are small (<2K rows total) so the saved time
-- is modest, but every retired write is also a §14 reduction.

-- =========================================================================
-- 3. Indexes on the new columns
-- =========================================================================
-- Single-column indexes for direct lookups, plus a few composites for the
-- hottest JOIN patterns (mirrors postgres ref's message_creatorid +
-- message_forumid + message_replyof + forum_moderatorid).

-- Only one live denorm-column index remains: idx_post_creator_id (used by IC10).
-- Tier 3 (2026-05-15) retired idx_tag_tagclass_id + idx_tagclass_subclass_of_id
-- because IC12 (their only past consumer) now traverses HAS_TYPE / IS_SUBCLASS_OF
-- via Cypher. All other denorm-column indexes were retired earlier:
--   idx_post_forum_id, idx_post_forum_creator (Tier 1)
--   idx_comment_creator_id, idx_comment_reply_of_id (Tier 2)
-- Migration `migrations/2026-05-15-tier3-drop-unused-indexes.sql` drops these
-- from existing deployments (DROP INDEX IS allowed by AGE 1.6, unlike DROP COLUMN).
CREATE INDEX IF NOT EXISTS idx_post_creator_id ON "Post" (creator_id);

-- =========================================================================
-- 4. Per-friend top-K message composite indexes — DROPPED (IC2 rewrite 2026-05-13)
-- These (creator_id, creationDate DESC) composites were IC2's only callers.
-- IC2 is now a single Cypher call that filters creationDate inside Cypher,
-- which uses the agtype functional indexes (idx_post_creationdate_agtype,
-- idx_comment_creationdate_agtype) in create-indexes.sql instead.
-- Dropping here so they are not created on fresh loads; the DROP below is
-- idempotent for existing deployments.
-- =========================================================================
DROP INDEX IF EXISTS ldbc_snb.idx_post_creator_creationdate;
DROP INDEX IF EXISTS ldbc_snb.idx_comment_creator_creationdate;

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

-- 3A: Composite mirror of FMPC PK for IC5's two-column probe. PK is
-- (forum_id, member_id); IC5 drives from friend graphids and joins on both
-- columns. Without this, planner builds a 7 MB hash on full FMPC (610k rows
-- at SF10, ~6M at SF100) that spills to 16 batches. With it, NL-via-index
-- returns at most 1 row per probe.
CREATE INDEX IF NOT EXISTS idx_fmpc_member_forum
    ON "ForumMemberPostCount" (member_id, forum_id);

-- Drop the now-redundant single-column index; the composite covers all
-- WHERE member_id = ? use cases as a leading prefix.
DROP INDEX IF EXISTS idx_fmpc_member;

-- 3B (revised 2026-05-13): client directive — never directly access AGE-managed
-- tables in outer SQL. Replaces the prior HAS_MEMBER.join_date denorm column
-- (which violated the directive) with two side tables that mirror the AGE
-- state IC5 needs. IC5/IU5 read/write the side tables; AGE tables remain
-- accessible only via cypher() calls.
--
-- HasMemberSide — mirror of HAS_MEMBER edges (forum_id, member_id, join_date).
-- PK is (member_id, forum_id) because IC5 drives from the friend (member) side.
-- Maintained by IU5 (INSERT per AddForumMembership). Initial backfill below.
CREATE TABLE IF NOT EXISTS "HasMemberSide" (
  forum_id   ag_catalog.graphid NOT NULL,
  member_id  ag_catalog.graphid NOT NULL,
  join_date  bigint             NOT NULL,
  PRIMARY KEY (member_id, forum_id)
);
CREATE INDEX IF NOT EXISTS idx_hms_member_joindate
    ON "HasMemberSide" (member_id, join_date);

-- ForumSide — mirror of Forum vertex properties IC5 needs in its RETURN/ORDER BY.
-- forum_id is the AGE graphid (used for joining); forum_business_id is the LDBC
-- public id used as IC5's tie-breaker. Maintained by IU4 (INSERT per AddForum).
CREATE TABLE IF NOT EXISTS "ForumSide" (
  forum_id           ag_catalog.graphid PRIMARY KEY,
  forum_business_id  bigint             NOT NULL,
  title              text               NOT NULL
);

-- CommentRootPost — for each Comment, the LDBC business id (bigint) of the
-- root Post reached by following REPLY_OF*. Used by IS6 (currently falls back
-- to its own SQL walk; pending future refactor) and IS2 (consumes the
-- comment_business_id lookup). Storing the business id (not graphid) lets
-- queries use `MATCH (root:Post {id: $rid})` directly inside Cypher when needed.
-- Maintained by IU7 on AddComment. Backfilled below.
--
-- 2026-05-14: added comment_business_id column with a unique index, so IS2
-- can look up a Comment's root post by its LDBC bigint id without joining
-- the AGE Comment label table. The original comment_id (graphid) PK remains
-- so the iterative backfill loop can join against the REPLY_OF edge table
-- (Comment.reply_of_id was retired 2026-05-14; backfill now traverses
-- the REPLY_OF edge table directly).
CREATE TABLE IF NOT EXISTS "CommentRootPost" (
  comment_id            ag_catalog.graphid PRIMARY KEY,
  comment_business_id   bigint             NOT NULL,
  root_post_business_id bigint             NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_commentrootpost_business_id
    ON "CommentRootPost" (comment_business_id);

-- Drop the prior Phase 3B denorm index on the AGE-managed HAS_MEMBER table.
-- Note: the column itself (HAS_MEMBER.join_date) cannot be dropped — AGE 1.6
-- blocks ALTER on its label tables ("table HAS_MEMBER is for label HAS_MEMBER").
-- The column remains as dead storage but is no longer indexed or referenced.
DROP INDEX IF EXISTS idx_hasmember_end_joindate;
DROP INDEX IF EXISTS idx_hasmember_end_joindate_agtype;

-- 5b. PersonPostCount: 1 row per Person, total post_count. Side table
-- (NOT on the Person label) because AGE 1.6 cannot handle extra columns
-- with NOT NULL DEFAULT on its label tables — Cypher CREATE segfaults.
-- Maintained at IU6 (increment); load-time backfill from Post.creator_id.
CREATE TABLE IF NOT EXISTS "PersonPostCount" (
  person_id  ag_catalog.graphid PRIMARY KEY,
  post_count int                NOT NULL DEFAULT 0
);

-- 5d (2026-05-14): Phase C side tables for IC9.
-- AGENTS.md §14 forbids outer-SQL reads of AGE label tables, so the prior
-- IC9 hybrid (date-DESC walk on Comment/Post via HAS_CREATOR joins) is out.
-- A Cypher-only shape on a HAS_CREATOR edge property failed gate (240x at
-- SF3 — AGE can't push LIMIT past UNION, and edge-property predicates don't
-- bind as Index Cond on functional indexes).
--
-- MessageByCreator: one row per (Comment | Post), keyed by creator's LDBC
-- business id (bigint). Composite index gives per-creator date-DESC walks
-- with a true Index Cond on `creation_date`, enabling the LATERAL LIMIT 20
-- per-friend shape used by IC9. Maintained by IU6/IU7. Backfilled below.
CREATE TABLE IF NOT EXISTS "MessageByCreator" (
  creator_business_id bigint  NOT NULL,
  message_business_id bigint  NOT NULL,
  creation_date       bigint  NOT NULL,
  content             text,
  is_post             boolean NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_msgbycreator_creator_date_msg
  ON "MessageByCreator" (creator_business_id, creation_date DESC, message_business_id);
-- Secondary unique index by message_business_id alone — IS2 looks up a
-- specific root post by its business id without scanning per-creator.
CREATE UNIQUE INDEX IF NOT EXISTS idx_msgbycreator_message
  ON "MessageByCreator" (message_business_id);

-- PersonSide: small mirror of Person {id, firstName, lastName} for projection
-- queries that cannot read Person directly. PK on business id (bigint) so
-- friend-set joins from cypher() outputs are native bigint comparisons.
-- Maintained by IU1.
CREATE TABLE IF NOT EXISTS "PersonSide" (
  person_business_id bigint PRIMARY KEY,
  first_name         text   NOT NULL,
  last_name          text   NOT NULL
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

-- HasMemberSide: snapshot of HAS_MEMBER edges. Direct SQL — §14 governs
-- read queries; backfills running at deploy time are exempt. The cypher()
-- variant this replaces was ~5-10x slower at SF10 (Cypher executor overhead
-- per row vs. native PostgreSQL table scan).
INSERT INTO "HasMemberSide" (forum_id, member_id, join_date)
SELECT
  hm.start_id,
  hm.end_id,
  CAST(ag_catalog.agtype_object_field_text(hm.properties, 'joinDate') AS bigint)
FROM "HAS_MEMBER" hm
ON CONFLICT (member_id, forum_id) DO NOTHING;

-- ForumSide: snapshot of Forum vertex properties used by IC5. Direct SQL —
-- see HasMemberSide note above.
INSERT INTO "ForumSide" (forum_id, forum_business_id, title)
SELECT
  f.id,
  CAST(ag_catalog.agtype_object_field_text(f.properties, 'id') AS bigint),
  ag_catalog.agtype_object_field_text(f.properties, 'title')
FROM "Forum" f
ON CONFLICT (forum_id) DO NOTHING;

-- CommentRootPost: precomputed mapping Comment → root Post business id.
-- IS6 needs this because AGE 1.6 cannot express the REPLY_OF* walk in Cypher
-- (untyped intermediates break on Person's denorm columns).
--
-- Backfill via iterative depth-bounded INSERTs instead of a WITH RECURSIVE
-- CTE: each iteration adds the Comments whose immediate parent already has
-- a known root, and the loop exits when an iteration adds zero rows. Each
-- pass is a single indexed join (CommentRootPost.comment_id PK ⋈ REPLY_OF
-- edge table), which is much cheaper than the recursive CTE's repeated
-- materialization of intermediate chain rows. At SF10 with ~10-deep reply
-- chains, the loop converges in 10-15 passes and runs ~3x faster than the
-- recursive form.
--
-- Comment.reply_of_id retired 2026-05-14 — backfill now traverses the
-- REPLY_OF edge table directly (no dependency on the retired denorm column).
--
-- Seed: every Comment whose direct parent is a Post.
INSERT INTO "CommentRootPost" (comment_id, comment_business_id, root_post_business_id)
SELECT c.id,
       CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint),
       CAST(ag_catalog.agtype_object_field_text(p.properties, 'id') AS bigint)
FROM "Comment" c
JOIN "REPLY_OF" r ON r.start_id = c.id
JOIN "Post"     p ON p.id = r.end_id
ON CONFLICT (comment_id) DO NOTHING;

-- Walk upward through the chain in layers, one chain-depth per iteration.
DO $$
DECLARE
  added bigint;
  depth int := 1;
BEGIN
  LOOP
    INSERT INTO "CommentRootPost" (comment_id, comment_business_id, root_post_business_id)
    SELECT c.id,
           CAST(ag_catalog.agtype_object_field_text(c.properties, 'id') AS bigint),
           parent.root_post_business_id
    FROM "Comment" c
    JOIN "REPLY_OF" r ON r.start_id = c.id
    JOIN "CommentRootPost" parent ON parent.comment_id = r.end_id
    WHERE NOT EXISTS (
      SELECT 1 FROM "CommentRootPost" existing
       WHERE existing.comment_id = c.id
    );
    GET DIAGNOSTICS added = ROW_COUNT;
    EXIT WHEN added = 0;
    depth := depth + 1;
  END LOOP;
  RAISE NOTICE 'CommentRootPost: converged after % chain layers', depth;
END $$;

-- ForumMemberPostCount: aggregate Posts per (forum, creator) pair.
-- Post.forum_id retired 2026-05-14; source the forum graphid directly from
-- the CONTAINER_OF edge table (start_id = forum, end_id = post) joined to
-- Post.creator_id. ON CONFLICT DO NOTHING makes this idempotent.
INSERT INTO "ForumMemberPostCount" (forum_id, member_id, post_count)
SELECT co.start_id, p.creator_id, COUNT(*)::int
FROM "Post" p
JOIN "CONTAINER_OF" co ON co.end_id = p.id
WHERE p.creator_id IS NOT NULL
GROUP BY co.start_id, p.creator_id
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

-- PersonSide: mirror Person {id, firstName, lastName} for IC9 + future use.
-- Driven by the already-loaded "Person" vertex table. Idempotent.
INSERT INTO "PersonSide" (person_business_id, first_name, last_name)
SELECT
  CAST(ag_catalog.agtype_object_field_text(properties, 'id') AS bigint),
  ag_catalog.agtype_object_field_text(properties, 'firstName'),
  ag_catalog.agtype_object_field_text(properties, 'lastName')
FROM "Person"
ON CONFLICT (person_business_id) DO NOTHING;

-- MessageByCreator: mirror Comment + Post with creator, date, and content.
-- Comment leg: Comment.creator_id retired 2026-05-14 — traverse HAS_CREATOR
-- directly. Post leg: Post.creator_id still live (read by IC10).
INSERT INTO "MessageByCreator" (creator_business_id, message_business_id, creation_date, content, is_post)
SELECT
  CAST(ag_catalog.agtype_object_field_text(per.properties, 'id') AS bigint),
  CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint),
  CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint),
  ag_catalog.agtype_object_field_text(msg.properties, 'content'),
  false
FROM "Comment" msg
JOIN "HAS_CREATOR" hc ON hc.start_id = msg.id
JOIN "Person"      per ON per.id = hc.end_id
UNION ALL
SELECT
  CAST(ag_catalog.agtype_object_field_text(per.properties, 'id') AS bigint),
  CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint),
  CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint),
  COALESCE(
    ag_catalog.agtype_object_field_text(msg.properties, 'content'),
    ag_catalog.agtype_object_field_text(msg.properties, 'imageFile')
  ),
  true
FROM "Post" msg
JOIN "Person" per ON per.id = msg.creator_id
ON CONFLICT DO NOTHING;

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
ANALYZE "MessageByCreator";
ANALYZE "PersonSide";
ANALYZE "HAS_INTEREST";
ANALYZE "HAS_TAG";
