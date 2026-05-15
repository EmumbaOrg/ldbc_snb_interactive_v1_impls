-- Tier 3 (2026-05-15): drop indexes on retired denorm columns that AGE 1.6
-- left in place because `ALTER TABLE ... DROP COLUMN` is blocked on label
-- tables. DROP INDEX IS allowed, so we recover the index storage and write
-- amortisation even though the columns themselves stay on disk as NULL.
--
-- All indexes named below were CREATEd by earlier versions of
-- `scripts/denormalize-schema.sql`. The corresponding columns have been
-- retired across the IU §14 cleanup and the IC12 Cypher migration:
--
--   * Tag.tagclass_id            — IC12 now traverses HAS_TYPE via Cypher.
--   * TagClass.subclass_of_id    — IC12 now traverses IS_SUBCLASS_OF via Cypher.
--   * Post.country_id            — no consumer.
--   * Comment.country_id         — no consumer.
--   * Forum.moderator_id         — no consumer.
--   * Person.city_id             — no consumer.
--   * City.country_id            — no consumer.
--   * Country.continent_id       — no consumer.
--   * University.city_id         — no consumer.
--   * Company.country_id         — no consumer.
--
-- Tier 1 (Post.forum_id) and Tier 2 (Comment.creator_id, Comment.reply_of_id)
-- index drops are handled by earlier migrations:
--   migrations/2026-05-14-drop-post-forum-id.sql
--   migrations/2026-05-14-retire-comment-creator-replyof.sql
--
-- Idempotent: all DROPs use IF EXISTS.

DROP INDEX IF EXISTS ldbc_snb.idx_tag_tagclass_id;
DROP INDEX IF EXISTS ldbc_snb.idx_tagclass_subclass_of_id;

-- Place-hierarchy + organisation indexes (if any were ever created — older
-- versions of denormalize-schema.sql may have had them).
DROP INDEX IF EXISTS ldbc_snb.idx_post_country_id;
DROP INDEX IF EXISTS ldbc_snb.idx_comment_country_id;
DROP INDEX IF EXISTS ldbc_snb.idx_forum_moderator_id;
DROP INDEX IF EXISTS ldbc_snb.idx_person_city_id;
DROP INDEX IF EXISTS ldbc_snb.idx_city_country_id;
DROP INDEX IF EXISTS ldbc_snb.idx_country_continent_id;
DROP INDEX IF EXISTS ldbc_snb.idx_university_city_id;
DROP INDEX IF EXISTS ldbc_snb.idx_company_country_id;

-- Future (when AGE 1.7+ relaxes the label-table DROP COLUMN guard,
-- or via a graph rebuild): uncomment these to actually reclaim the
-- column storage. Currently blocked by:
--   ERROR: table "Post" is for label "Post"
-- (and equivalent for every label table).
--
-- ALTER TABLE ldbc_snb."Post"       DROP COLUMN IF EXISTS country_id;
-- ALTER TABLE ldbc_snb."Comment"    DROP COLUMN IF EXISTS country_id;
-- ALTER TABLE ldbc_snb."Forum"      DROP COLUMN IF EXISTS moderator_id;
-- ALTER TABLE ldbc_snb."Person"     DROP COLUMN IF EXISTS city_id;
-- ALTER TABLE ldbc_snb."Tag"        DROP COLUMN IF EXISTS tagclass_id;
-- ALTER TABLE ldbc_snb."TagClass"   DROP COLUMN IF EXISTS subclass_of_id;
-- ALTER TABLE ldbc_snb."City"       DROP COLUMN IF EXISTS country_id;
-- ALTER TABLE ldbc_snb."Country"    DROP COLUMN IF EXISTS continent_id;
-- ALTER TABLE ldbc_snb."University" DROP COLUMN IF EXISTS city_id;
-- ALTER TABLE ldbc_snb."Company"    DROP COLUMN IF EXISTS country_id;
