-- Tier 3b (2026-05-15): retire Post.creator_id — the last live denorm column.
--
-- IC10 was migrated to use MessageByCreator.message_id (a new graphid column)
-- for its HAS_TAG join, so the outer-SQL filter `post.creator_id = friend_gid`
-- is replaced by `m.creator_business_id = friend_biz_id AND m.is_post`. IU6's
-- `UPDATE Post SET creator_id` is also removed. denormalize-schema.sql no
-- longer ADDs the column or CREATEs idx_post_creator_id on fresh loads.
--
-- This migration does two things on existing deployments:
--   1. Extend MessageByCreator with a `message_id ag_catalog.graphid` column
--      and backfill it from HAS_CREATOR. IC10's V3 shape joins HAS_TAG by
--      this graphid, so without the backfill IC10 would return zero common
--      posts for every friend on a pre-migration MessageByCreator row.
--   2. DROP INDEX idx_post_creator_id. The column itself stays on disk as
--      NULL because AGE 1.6 blocks `ALTER TABLE ... DROP COLUMN` on label
--      tables (the C-level ProcessUtility guard refuses with
--      "table X is for label X" even with CASCADE). Future AGE versions
--      that relax this can run the commented-out DROP COLUMN below.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, DROP INDEX IF EXISTS, backfill is
-- WHERE message_id IS NULL.

BEGIN;

-- 1. Extend MessageByCreator with the graphid column.
ALTER TABLE ldbc_snb."MessageByCreator"
  ADD COLUMN IF NOT EXISTS message_id ag_catalog.graphid;

-- 2. Backfill from the Comment / Post label tables. The `id` graphid column
--    is the row PK and matches Cypher's id() output. The business id is
--    extracted via ag_catalog.agtype_object_field_text — the matching
--    expression index `idx_comment_id` / `idx_post_id` already exists so
--    the join binds to an index scan, not a seq scan.
UPDATE ldbc_snb."MessageByCreator" m
   SET message_id = c.id
  FROM ldbc_snb."Comment" c
 WHERE m.message_business_id =
         (ag_catalog.agtype_object_field_text(c.properties, 'id'::text))::bigint
   AND m.is_post = false
   AND m.message_id IS NULL;

UPDATE ldbc_snb."MessageByCreator" m
   SET message_id = p.id
  FROM ldbc_snb."Post" p
 WHERE m.message_business_id =
         (ag_catalog.agtype_object_field_text(p.properties, 'id'::text))::bigint
   AND m.is_post = true
   AND m.message_id IS NULL;

-- 3. After backfill, enforce NOT NULL so future inserts can't skip it.
ALTER TABLE ldbc_snb."MessageByCreator"
  ALTER COLUMN message_id SET NOT NULL;

-- 4. Secondary index so IC10's `WHERE ht.start_id = m.message_id` can
--    bind to MessageByCreator from the HAS_TAG side too.
CREATE INDEX IF NOT EXISTS idx_messagebycreator_message_id
  ON ldbc_snb."MessageByCreator" (message_id);

-- 5. Drop the now-unused index on Post.creator_id.
DROP INDEX IF EXISTS ldbc_snb.idx_post_creator_id;

COMMIT;

-- Future (AGE 1.7+ or graph rebuild): reclaim the column itself.
-- Currently blocked by AGE 1.6 ProcessUtility guard:
--   ERROR: table "Post" is for label "Post"
--
-- ALTER TABLE ldbc_snb."Post" DROP COLUMN IF EXISTS creator_id;
