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
-- ALL label-table denorm columns are retired as of 2026-05-15 (Tier 3b).
-- Post.creator_id — the last live denorm column — was retired when IC10
-- migrated to use MessageByCreator.message_id for the HAS_TAG join.
--
-- Retired column inventory (NOT created on fresh loads after 2026-05-15):
--   Post:        forum_id, country_id, creator_id        (creator_id Tier 3b)
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
-- (or via a full graph rebuild). Migrations
-- `migrations/2026-05-15-tier3-drop-unused-indexes.sql` and
-- `migrations/2026-05-15-tier3b-drop-post-creator-id-usage.sql`
-- drop the matching indexes (which IS allowed by AGE 1.6).

-- (no ALTER TABLE ADD COLUMN statements remain; section retained for
--  context. Future denorm columns added here would land in this section.)

-- =========================================================================
-- 2. Load-time backfill from edge tables
-- =========================================================================
-- All label-table denorm-column backfills are retired as of 2026-05-15 (Tier 3b).
-- Backfill of message_id on MessageByCreator happens inline with the MessageByCreator
-- INSERT in section 6 (using HAS_CREATOR + Post/Comment.id directly).

-- Post.creator_id retired 2026-05-15 (Tier 3b): IC10 migrated to use
-- MessageByCreator.message_id; IU6 no longer writes Post.creator_id.
-- Post.forum_id retired 2026-05-14: IU6 sources forum gid from Cypher RETURN.
-- Post.country_id retired 2026-05-14: no read consumers.
-- Comment.{creator_id, reply_of_id, country_id} retired 2026-05-14.
-- Forum.moderator_id, Person.city_id retired 2026-05-14.
-- Tag.tagclass_id, TagClass.subclass_of_id retired 2026-05-15 (Tier 3).
-- City.country_id, Country.continent_id, University.city_id, Company.country_id
-- retired 2026-05-14.
--
-- All retired columns persist as NULL on existing deployments (AGE 1.6 blocks
-- `ALTER TABLE ... DROP COLUMN` on label tables). Corresponding indexes dropped by:
--   migrations/2026-05-14-drop-post-forum-id.sql           (Tier 1)
--   migrations/2026-05-14-retire-comment-creator-replyof.sql (Tier 2)
--   migrations/2026-05-15-tier3-drop-unused-indexes.sql    (Tier 3)
--   migrations/2026-05-15-tier3b-drop-post-creator-id-usage.sql (Tier 3b)

-- =========================================================================
-- 3. Indexes on the new columns
-- =========================================================================
-- All denorm-column indexes are retired as of 2026-05-15 (Tier 3b).
-- The last live denorm-column index, idx_post_creator_id, was retired when
-- IC10 migrated to use MessageByCreator.message_id (which has its own
-- composite + secondary indexes — see section 5d below). Existing deployments
-- drop idx_post_creator_id via migrations/2026-05-15-tier3b-drop-post-creator-id-usage.sql.

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

-- 3B (2026-05-13 original, retired Phase A 2026-05-28): HasMemberSide and
-- ForumSide were §14-compliance workarounds for trivial HAS_MEMBER edge
-- property reads and Forum scalar property reads. Phase A retires them:
-- IC5 now projects m.joinDate, forum.title, and forum.id directly from the
-- Cypher block's RETURN, and IU5 no longer maintains HasMemberSide.
-- Drop stale tables/indexes for any pre-Phase-A deployment:
DROP TABLE  IF EXISTS "HasMemberSide";
DROP TABLE  IF EXISTS "ForumSide";
DROP INDEX  IF EXISTS idx_hms_member_joindate;

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

-- PersonPostCount: retired Phase B 2026-05-29. Was a per-Person post-count
-- counter cache read only by IC10. IC10 now computes total post count inline as
-- COUNT(*) over MessageByCreator (is_post=true) in the same LATERAL that computes
-- common_post_count. IU1 no longer seeds it; IU6 no longer increments it. Drop
-- stale table for any pre-Phase-B deployment:
DROP TABLE IF EXISTS "PersonPostCount";

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
--
-- The `message_id` (graphid) column was added 2026-05-15 so IC10 can JOIN
-- HAS_TAG by graphid without reading the AGE Post label table — this lets
-- us retire Post.creator_id (the last live denorm column).
CREATE TABLE IF NOT EXISTS "MessageByCreator" (
  creator_business_id bigint            NOT NULL,
  message_business_id bigint            NOT NULL,
  message_id          ag_catalog.graphid NOT NULL,
  creation_date       bigint            NOT NULL,
  content             text,
  is_post             boolean           NOT NULL
);
-- For existing tables created before 2026-05-15: ensure the new column exists
-- (idempotent — no-op if already added by Tier 3b migration).
ALTER TABLE "MessageByCreator" ADD COLUMN IF NOT EXISTS message_id ag_catalog.graphid;
CREATE UNIQUE INDEX IF NOT EXISTS idx_msgbycreator_creator_date_msg
  ON "MessageByCreator" (creator_business_id, creation_date DESC, message_business_id);
-- Secondary unique index by message_business_id alone — IS2 looks up a
-- specific root post by its business id without scanning per-creator.
CREATE UNIQUE INDEX IF NOT EXISTS idx_msgbycreator_message
  ON "MessageByCreator" (message_business_id);

-- PersonSide: retired Phase A 2026-05-28. Was a §14-compliance workaround
-- for trivial Person scalar property reads (firstName, lastName). IC9 now
-- projects f.firstName/f.lastName directly from the Cypher RETURN; IS2 uses
-- GIN-indexed scalar subqueries against the Person label table. IU1 no longer
-- maintains PersonSide. Drop stale table for any pre-Phase-A deployment:
DROP TABLE IF EXISTS "PersonSide";

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

-- HasMemberSide backfill: retired Phase A 2026-05-28 (table dropped above).
-- ForumSide backfill: retired Phase A 2026-05-28 (table dropped above).

-- CommentRootPost is loaded from preprocess-emitted CSV by load-side-tables.py
-- (run as a separate step from load-data.sh after this script). The \copy
-- approach previously here failed inside `psql -f` with sed-substituted paths;
-- copy_expert over libpq is robust and works against managed Horizon DB.

-- ForumMemberPostCount: aggregate Posts per (forum, creator) pair.
-- Post.forum_id retired 2026-05-14, Post.creator_id retired 2026-05-15 (Tier 3b);
-- both edges are now sourced directly from CONTAINER_OF + HAS_CREATOR.
-- ON CONFLICT DO NOTHING makes this idempotent.
INSERT INTO "ForumMemberPostCount" (forum_id, member_id, post_count)
SELECT co.start_id, hc.end_id, COUNT(*)::int
FROM "Post" p
JOIN "CONTAINER_OF" co ON co.end_id = p.id
JOIN "HAS_CREATOR"  hc ON hc.start_id = p.id
GROUP BY co.start_id, hc.end_id
ON CONFLICT (forum_id, member_id) DO NOTHING;

-- PersonPostCount backfill: retired Phase B 2026-05-29 (table dropped above).
-- PersonSide backfill: retired Phase A 2026-05-28 (table dropped above).

-- MessageByCreator is loaded from preprocess-emitted CSV by load-side-tables.py
-- (run as a separate step from load-data.sh after this script). See the
-- CommentRootPost comment above for the rationale.

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
ANALYZE "MessageByCreator";
ANALYZE "HAS_INTEREST";
ANALYZE "HAS_TAG";
