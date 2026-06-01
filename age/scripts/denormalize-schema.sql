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

-- 5a. ForumMemberPostCount: RETIRED Milestone A 2026-05-30.
-- Was a precomputed per-(forum, member) post count used by IC5.
-- IC5 now computes the count inline via Cypher with WITH DISTINCT staging.
-- No peer impl (postgres/duckdb/umbra/cypher/tigergraph) precomputes this.
-- Un-retire when: AGE gains predicate pushdown / index binding through Cypher
-- (AGE #1000) so the per-pair count can use an index-backed traversal.
DROP TABLE IF EXISTS "ForumMemberPostCount";
DROP INDEX IF EXISTS idx_fmpc_member;
DROP INDEX IF EXISTS idx_fmpc_member_forum;

-- 3B (2026-05-13 original, retired Phase A 2026-05-28): HasMemberSide and
-- ForumSide were §14-compliance workarounds for trivial HAS_MEMBER edge
-- property reads and Forum scalar property reads. Phase A retires them:
-- IC5 now projects m.joinDate, forum.title, and forum.id directly from the
-- Cypher block's RETURN, and IU5 no longer maintains HasMemberSide.
-- Drop stale tables/indexes for any pre-Phase-A deployment:
DROP TABLE  IF EXISTS "HasMemberSide";
DROP TABLE  IF EXISTS "ForumSide";
DROP INDEX  IF EXISTS idx_hms_member_joindate;

-- CommentRootPost: RETIRED Milestone A 2026-05-30.
-- Was a transitive-closure cache (comment → root Post) used by IS2.
-- IS2's root-post lookup is deferred to Milestone B (VLE): REPLY_OF*0..
-- crashes AGE 1.6 backend. IS2 returns message's own id as a placeholder
-- for the root post id until Milestone B.
-- IS6 already has its own self-contained SQL recursive CTE over REPLY_OF
-- and never read this table at runtime.
-- No peer impl maintains an equivalent structure.
DROP TABLE IF EXISTS "CommentRootPost";
DROP INDEX IF EXISTS idx_commentrootpost_business_id;

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

-- MessageByCreator: RETIRED Milestone A 2026-05-30.
-- Was a creator-keyed mirror of Comment+Post used by IC2/IC9/IS2/IC10.
-- IC2/IC9 now use canonical Cypher UNION arms (Comment + Post HAS_CREATOR).
-- IC10 now uses Cypher OPTIONAL MATCH with WITH DISTINCT staging for count.
-- IS2 canonical message walk uses Cypher UNION arms; root-post deferred to B.
-- No peer impl (postgres/duckdb/umbra/cypher/tigergraph) maintains an
-- equivalent structure — peers compute inline with per-creator FK index + sort.
-- Un-retire when: AGE gains LIMIT pushdown past Cypher UNION (currently
-- materialises full row set before sort — AGE structural limit #1).
DROP TABLE IF EXISTS "MessageByCreator";
DROP INDEX IF EXISTS idx_msgbycreator_creator_date_msg;
DROP INDEX IF EXISTS idx_msgbycreator_message;

-- PersonSide: retired Phase A 2026-05-28. Was a §14-compliance workaround
-- for trivial Person scalar property reads (firstName, lastName). IC9 now
-- projects f.firstName/f.lastName directly from the Cypher RETURN; IS2 uses
-- GIN-indexed scalar subqueries against the Person label table. IU1 no longer
-- maintains PersonSide. Drop stale table for any pre-Phase-A deployment:
DROP TABLE IF EXISTS "PersonSide";

-- 5c. (Removed) composite HAS_INTEREST(start_id, end_id). It served the old
-- IC10 SQL semi-join `EXISTS (SELECT 1 FROM HAS_INTEREST WHERE start_id=p AND
-- end_id=t)`. The 2026-06-01 IC10 fix moved tag-overlap into a Cypher EXISTS{}
-- semi-join that binds idx_hasinterest_start; the composite was then never
-- scanned (pg_stat_user_indexes idx_scan = 0).
DROP INDEX IF EXISTS idx_hasinterest_start_end;

-- =========================================================================
-- 6. Iteration-2 backfills
-- =========================================================================

-- HasMemberSide backfill: retired Phase A 2026-05-28 (table dropped above).
-- ForumSide backfill: retired Phase A 2026-05-28 (table dropped above).
-- ForumMemberPostCount backfill: retired Milestone A 2026-05-30 (table dropped above).
-- PersonPostCount backfill: retired Phase B 2026-05-29 (table dropped above).
-- PersonSide backfill: retired Phase A 2026-05-28 (table dropped above).
-- MessageByCreator backfill: retired Milestone A 2026-05-30 (table dropped above).
-- CommentRootPost backfill: retired Milestone A 2026-05-30 (table dropped above).

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
ANALYZE "HAS_INTEREST";
ANALYZE "HAS_TAG";
