-- Index strategy for Apache AGE LDBC SNB graph (AGE 1.6.0+)
-- Run once after agefreighter load, before benchmarking.
--
-- WHY GIN, NOT B-TREE, FOR VERTEX PROPERTY LOOKUPS
-- AGE compiles Cypher MATCH with a property filter — e.g. MATCH (p:Person {id: $personId}) —
-- to a PostgreSQL containment predicate:  properties @> '{"id": 933}'::agtype
-- The containment operator (@>) requires a GIN index with the gin_agtype_ops operator class.
-- B-tree indexes on CAST(agtype_object_field_text(properties,'id') AS bigint) do NOT support
-- @> and are never used by the planner for these patterns.
--
-- agefreighter already creates GIN-on-properties and B-tree-on-id/start_id/end_id automatically.
-- The GIN and edge-traversal indexes below are idempotent (IF NOT EXISTS) — safe to re-run,
-- and necessary for the dev path (load-test-data.py) which skips agefreighter.
--
-- B-tree indexes on extracted property values ARE useful for WHERE-clause range/equality
-- filters (creationDate ranges, name equality) where the planner can use a functional index.
-- These are NOT created by agefreighter.

LOAD 'age';
SET search_path = ag_catalog, '$user', public;

-- ---------------------------------------------------------------------------
-- GIN indexes on vertex properties
-- Enables efficient MATCH (n:Label {id: X}) / {name: Y} containment lookups.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS gin_person      ON ldbc_snb."Person"     USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_comment     ON ldbc_snb."Comment"    USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_post        ON ldbc_snb."Post"        USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_forum       ON ldbc_snb."Forum"       USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_tag         ON ldbc_snb."Tag"         USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_tagclass    ON ldbc_snb."TagClass"    USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_city        ON ldbc_snb."City"        USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_country     ON ldbc_snb."Country"     USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_continent   ON ldbc_snb."Continent"   USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_company     ON ldbc_snb."Company"     USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_university  ON ldbc_snb."University"  USING GIN (properties ag_catalog.gin_agtype_ops);

-- ---------------------------------------------------------------------------
-- B-tree indexes on extracted date values
-- Supports WHERE-clause range filters: msg.creationDate < $maxDate (IC2, IC3, IC4, IC7, IC9)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_comment_date ON ldbc_snb."Comment" (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint));
CREATE INDEX IF NOT EXISTS idx_post_date    ON ldbc_snb."Post"    (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint));

-- ---------------------------------------------------------------------------
-- B-tree indexes on extracted name values
-- Supports WHERE-clause equality: tag.name = $tagName, country.name = $countryName (IC3, IC4, IC5, IC6, IC11)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_tag_name      ON ldbc_snb."Tag"      (agtype_object_field_text(properties, 'name'));
CREATE INDEX IF NOT EXISTS idx_tagclass_name ON ldbc_snb."TagClass" (agtype_object_field_text(properties, 'name'));
CREATE INDEX IF NOT EXISTS idx_country_name  ON ldbc_snb."Country"  (agtype_object_field_text(properties, 'name'));

-- ---------------------------------------------------------------------------
-- B-tree indexes on edge start_id / end_id
-- Supports adjacency traversal for all MATCH patterns following edge hops.
-- (agefreighter creates these automatically; included here for the dev load path.)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_knows_start        ON ldbc_snb."KNOWS"          (start_id);
CREATE INDEX IF NOT EXISTS idx_knows_end          ON ldbc_snb."KNOWS"          (end_id);
CREATE INDEX IF NOT EXISTS idx_hascreator_start   ON ldbc_snb."HAS_CREATOR"    (start_id);
CREATE INDEX IF NOT EXISTS idx_hascreator_end     ON ldbc_snb."HAS_CREATOR"    (end_id);
CREATE INDEX IF NOT EXISTS idx_replyof_start      ON ldbc_snb."REPLY_OF"       (start_id);
CREATE INDEX IF NOT EXISTS idx_replyof_end        ON ldbc_snb."REPLY_OF"       (end_id);
CREATE INDEX IF NOT EXISTS idx_hastag_start       ON ldbc_snb."HAS_TAG"        (start_id);
CREATE INDEX IF NOT EXISTS idx_hastag_end         ON ldbc_snb."HAS_TAG"        (end_id);
CREATE INDEX IF NOT EXISTS idx_likes_start        ON ldbc_snb."LIKES"          (start_id);
CREATE INDEX IF NOT EXISTS idx_likes_end          ON ldbc_snb."LIKES"          (end_id);
CREATE INDEX IF NOT EXISTS idx_containerof_start  ON ldbc_snb."CONTAINER_OF"   (start_id);
CREATE INDEX IF NOT EXISTS idx_containerof_end    ON ldbc_snb."CONTAINER_OF"   (end_id);
CREATE INDEX IF NOT EXISTS idx_hasmember_start    ON ldbc_snb."HAS_MEMBER"     (start_id);
CREATE INDEX IF NOT EXISTS idx_hasmember_end      ON ldbc_snb."HAS_MEMBER"     (end_id);
CREATE INDEX IF NOT EXISTS idx_islocatedin_start  ON ldbc_snb."IS_LOCATED_IN"  (start_id);
CREATE INDEX IF NOT EXISTS idx_islocatedin_end    ON ldbc_snb."IS_LOCATED_IN"  (end_id);
CREATE INDEX IF NOT EXISTS idx_hasinterest_start  ON ldbc_snb."HAS_INTEREST"   (start_id);
CREATE INDEX IF NOT EXISTS idx_hasinterest_end    ON ldbc_snb."HAS_INTEREST"   (end_id);
CREATE INDEX IF NOT EXISTS idx_workat_start       ON ldbc_snb."WORK_AT"        (start_id);
CREATE INDEX IF NOT EXISTS idx_workat_end         ON ldbc_snb."WORK_AT"        (end_id);
CREATE INDEX IF NOT EXISTS idx_studyat_start      ON ldbc_snb."STUDY_AT"       (start_id);
CREATE INDEX IF NOT EXISTS idx_studyat_end        ON ldbc_snb."STUDY_AT"       (end_id);
CREATE INDEX IF NOT EXISTS idx_hastype_start      ON ldbc_snb."HAS_TYPE"       (start_id);
CREATE INDEX IF NOT EXISTS idx_hastype_end        ON ldbc_snb."HAS_TYPE"       (end_id);
CREATE INDEX IF NOT EXISTS idx_issubclassof_start ON ldbc_snb."IS_SUBCLASS_OF" (start_id);
CREATE INDEX IF NOT EXISTS idx_issubclassof_end   ON ldbc_snb."IS_SUBCLASS_OF" (end_id);
CREATE INDEX IF NOT EXISTS idx_hasmoderator_start ON ldbc_snb."HAS_MODERATOR"  (start_id);
CREATE INDEX IF NOT EXISTS idx_hasmoderator_end   ON ldbc_snb."HAS_MODERATOR"  (end_id);
CREATE INDEX IF NOT EXISTS idx_ispartof_start     ON ldbc_snb."IS_PART_OF"     (start_id);
CREATE INDEX IF NOT EXISTS idx_ispartof_end       ON ldbc_snb."IS_PART_OF"     (end_id);
