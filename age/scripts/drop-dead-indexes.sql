-- One-time cleanup of dead indexes + retired side tables (LOCAL benchmark DB).
--
-- Every object below was confirmed unused via pg_stat_user_indexes (idx_scan = 0)
-- after a full local benchmark run, OR is a denorm side table retired by
-- Milestone A (2026-05-30) that lingers only because this DB predates that change.
--
-- Safe to re-run (all IF EXISTS). Does NOT touch the load-bearing core:
--   gin_person/comment/post/forum/tag/city/company/university, all *_graphid and
--   edge start_id/end_id B-trees, and idx_comment/post_creationdate_agtype.
--
-- This mirrors the CREATE-side pruning in create-indexes.sql / denormalize-schema.sql,
-- so a fresh load already produces the clean set — this file only fixes a stale DB.
--
-- Usage:  psql "$CONNECTION_STRING" -f scripts/drop-dead-indexes.sql
-- Run against LOCAL Pg17Age1.6 only — never shared Horizon infra.

SET search_path = ldbc_snb, ag_catalog, public;

-- --- Form-#2 CAST(agtype_object_field_text(... AS bigint)) date/id indexes -----
-- Anchors use {id: X} -> GIN; date ranges use the agtype-access form. Never scanned.
DROP INDEX IF EXISTS idx_comment_date;        -- 137 MB
DROP INDEX IF EXISTS idx_post_date;           --  54 MB
DROP INDEX IF EXISTS idx_comment_date_id;     -- 193 MB
DROP INDEX IF EXISTS idx_post_date_id;        --  78 MB
DROP INDEX IF EXISTS idx_person_id;
DROP INDEX IF EXISTS idx_comment_id;          -- 137 MB
DROP INDEX IF EXISTS idx_post_id;             --  56 MB
DROP INDEX IF EXISTS idx_forum_id;
DROP INDEX IF EXISTS idx_tag_id;
DROP INDEX IF EXISTS idx_tagclass_id;
DROP INDEX IF EXISTS idx_city_id;
DROP INDEX IF EXISTS idx_country_id;

-- --- Form-#1 agtype_object_field_text(...) name/firstName indexes --------------
-- Name/firstName filters use the {name:}/{firstName:} map form (-> GIN) or seq scan.
DROP INDEX IF EXISTS idx_tag_name;
DROP INDEX IF EXISTS idx_tagclass_name;
DROP INDEX IF EXISTS idx_country_name;
DROP INDEX IF EXISTS idx_person_firstname;

-- --- Useless reference-table GINs (planner always seq-scans these tables) ------
DROP INDEX IF EXISTS gin_country;
DROP INDEX IF EXISTS gin_tagclass;
DROP INDEX IF EXISTS gin_continent;

-- --- Orphaned composite: IC10 fix (2026-06-01) retired its only consumer -------
DROP INDEX IF EXISTS idx_hasinterest_start_end;   -- 17 MB

-- --- Retired denorm side tables (Milestone A 2026-05-30) — CASCADE drops idx ---
DROP TABLE IF EXISTS "MessageByCreator"     CASCADE;   -- ~1417 MB (heap + idx)
DROP TABLE IF EXISTS "CommentRootPost"      CASCADE;   --  ~594 MB
DROP TABLE IF EXISTS "ForumMemberPostCount" CASCADE;   --   ~25 MB
