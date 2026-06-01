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

SET search_path = ag_catalog, '$user', public;

-- ---------------------------------------------------------------------------
-- GIN indexes on vertex properties
-- Enables efficient MATCH (n:Label {id: X}) / {name: Y} containment lookups.
-- Country/TagClass/Continent GINs omitted: fixed-size reference tables (≤ a few
-- hundred rows at any SF) that the planner always seq-scans — their GINs were
-- never scanned (pg_stat_user_indexes idx_scan = 0).
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS gin_person      ON ldbc_snb."Person"     USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_comment     ON ldbc_snb."Comment"    USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_post        ON ldbc_snb."Post"        USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_forum       ON ldbc_snb."Forum"       USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_tag         ON ldbc_snb."Tag"         USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_city        ON ldbc_snb."City"        USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_company     ON ldbc_snb."Company"     USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX IF NOT EXISTS gin_university  ON ldbc_snb."University"  USING GIN (properties ag_catalog.gin_agtype_ops);

-- ---------------------------------------------------------------------------
-- Date range filters (msg.creationDate < $maxDate; IC2/IC3/IC4/IC9) are served by
-- the agtype-access-operator indexes at the bottom of this file. The
-- CAST(agtype_object_field_text(... AS bigint)) form was removed: AGE compiles the
-- Cypher predicate to agtype_access_operator(...), which the CAST form does not
-- match, so idx_comment_date / idx_post_date were never scanned (idx_scan = 0).
--
-- Name filters use either the {name: X} map form (→ GIN containment) or, on the
-- fixed-size reference tables, a seq scan. The agtype_object_field_text(...) form
-- (idx_tag_name / idx_tagclass_name / idx_country_name) matched neither and was
-- never scanned — removed.
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

-- ---------------------------------------------------------------------------
-- (Removed) vertex.id and Person.firstName functional B-trees, and the
-- Comment/Post (creationDate, id) composites — all CAST(agtype_object_field_text
-- (...)) / agtype_object_field_text(...) form. These never matched the queries:
--   * {id: X} / {firstName: X} anchors compile to `properties @>` → served by GIN.
--   * ORDER BY / LIMIT run in OUTER SQL over the agtype result columns, not inside
--     Cypher, so no in-Cypher access path picks a label-table functional index.
-- All were confirmed unused (pg_stat_user_indexes idx_scan = 0) after a full run.
-- Label-table joins use the graphid-`id` B-trees below; in-Cypher date ranges use
-- the agtype-access-operator date indexes at the bottom of this file.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Per-label B-tree indexes on the graphid `id` column
--
-- AGE inherits all label tables from `_ag_label_vertex`, which has
--   PRIMARY KEY (id).
-- PostgreSQL inheritance does NOT propagate the parent's PK to children, so
-- `Post`, `Comment`, `Forum`, `Person` and the rest of the vertex labels have
-- NO usable index on the graphid column. Any join of the form
--   JOIN <Label> v ON v.id = <some_graphid>
-- falls back to a Seq Scan on the entire label table — fine at SF0.1 (table
-- sizes in the tens of thousands), catastrophic at SF100+ (Post and Comment
-- exceed 1B rows at SF1000).
--
-- These indexes are required by the SQ6 pure-SQL rewrite (see
-- queries/interactive-short-6.sql) and benefit any other query that joins
-- back to a label table by graphid. Storage cost is negligible (8 bytes per
-- vertex; tiny vs the GIN on properties).
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_person_graphid     ON ldbc_snb."Person"     (id);
CREATE INDEX IF NOT EXISTS idx_comment_graphid    ON ldbc_snb."Comment"    (id);
CREATE INDEX IF NOT EXISTS idx_post_graphid       ON ldbc_snb."Post"       (id);
CREATE INDEX IF NOT EXISTS idx_forum_graphid      ON ldbc_snb."Forum"      (id);
CREATE INDEX IF NOT EXISTS idx_tag_graphid        ON ldbc_snb."Tag"        (id);
CREATE INDEX IF NOT EXISTS idx_tagclass_graphid   ON ldbc_snb."TagClass"   (id);
CREATE INDEX IF NOT EXISTS idx_city_graphid       ON ldbc_snb."City"       (id);
CREATE INDEX IF NOT EXISTS idx_country_graphid    ON ldbc_snb."Country"    (id);
CREATE INDEX IF NOT EXISTS idx_continent_graphid  ON ldbc_snb."Continent"  (id);
CREATE INDEX IF NOT EXISTS idx_company_graphid    ON ldbc_snb."Company"    (id);
CREATE INDEX IF NOT EXISTS idx_university_graphid ON ldbc_snb."University" (id);

-- ---------------------------------------------------------------------------
-- Edge-property indexes that match AGE's compiled Cypher predicate shape
--
-- AGE 1.6 compiles `member.joinDate > $minDate` to:
--   ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"joinDate"'::agtype]) > '...'::agtype
-- PostgreSQL's expression-index matching is byte-exact, so the existing
-- functional B-tree on `CAST(agtype_object_field_text(properties,'joinDate') AS bigint)`
-- (the form we'd use for pure-SQL queries) does NOT match this predicate
-- and is never picked. Indexing the agtype-access expression directly does
-- match — and lets the planner Bitmap Index Scan instead of Parallel Seq
-- Scan, which in turn unlocks Nested Loop access to downstream Post +
-- HAS_CREATOR + CONTAINER_OF instead of a Hash Join over the full tables.
--
-- Measured impact for IC5 at SF0.1: sample-1 451 ms → 292 ms (-35%);
-- sample-2 186 ms → 36 ms (-81%). The composite (end_id, joinDate)
-- shape additionally tightens the friend × date intersection.
--
-- Same trick should help any Cypher query with `<edge>.<property> <op> $param`
-- range predicates. Worth trying on Comment.creationDate / Post.creationDate
-- if those queries (IC2/IC9 etc.) ever flag at SF100+ in profiling.
-- ---------------------------------------------------------------------------
-- Native (end_id, join_date) B-tree index moved to denormalize-schema.sql
-- (after the join_date BIGINT ALTER+backfill). create-indexes.sql runs
-- BEFORE denormalize-schema.sql in load-data.sh, so the column doesn't yet
-- exist at this point.

-- Date predicates on Comment / Post for IC2/IC4-style date-range filters in Cypher.
-- These agtype-access-operator indexes match `comment.creationDate <= $maxDate` /
-- `post.creationDate >= $X` exactly as AGE 1.6 compiles them, and are the only
-- date indexes actually used (the CAST-as-bigint form never matched the compiled
-- Cypher predicate and was removed — see note above).
CREATE INDEX IF NOT EXISTS idx_comment_creationdate_agtype
  ON ldbc_snb."Comment" ((ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"creationDate"'::ag_catalog.agtype])));

CREATE INDEX IF NOT EXISTS idx_post_creationdate_agtype
  ON ldbc_snb."Post" ((ag_catalog.agtype_access_operator(VARIADIC ARRAY[properties, '"creationDate"'::ag_catalog.agtype])));
