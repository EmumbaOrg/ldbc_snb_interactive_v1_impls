-- B-tree indexes for Apache AGE LDBC SNB benchmark
-- AGE stores label tables in the graph's own schema: <graph_name>."<LabelName>"
-- Each table has columns: id (graphid), properties (agtype)
-- agtype does NOT support ->> operator; use ag_catalog.agtype_access_operator() instead
-- Run after data loading with: psql "$CONNECTION_STRING" -f create-indexes.sql

SET search_path = ag_catalog, ldbc_snb, public;

-- Vertex label indexes on the 'id' property (LDBC entity id stored inside properties)
CREATE INDEX IF NOT EXISTS idx_person_id ON ldbc_snb."Person" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_comment_id ON ldbc_snb."Comment" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_post_id ON ldbc_snb."Post" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_forum_id ON ldbc_snb."Forum" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_tag_id ON ldbc_snb."Tag" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_tagclass_id ON ldbc_snb."TagClass" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_city_id ON ldbc_snb."City" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_country_id ON ldbc_snb."Country" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_continent_id ON ldbc_snb."Continent" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_university_id ON ldbc_snb."University" ((ag_catalog.agtype_access_operator(properties, '"id"')));
CREATE INDEX IF NOT EXISTS idx_company_id ON ldbc_snb."Company" ((ag_catalog.agtype_access_operator(properties, '"id"')));

-- Edge label indexes on start_id and end_id (internal graph IDs for traversal)
CREATE INDEX IF NOT EXISTS idx_knows_start ON ldbc_snb."KNOWS" (start_id);
CREATE INDEX IF NOT EXISTS idx_knows_end ON ldbc_snb."KNOWS" (end_id);
CREATE INDEX IF NOT EXISTS idx_has_creator_start ON ldbc_snb."HAS_CREATOR" (start_id);
CREATE INDEX IF NOT EXISTS idx_has_creator_end ON ldbc_snb."HAS_CREATOR" (end_id);
CREATE INDEX IF NOT EXISTS idx_is_located_in_start ON ldbc_snb."IS_LOCATED_IN" (start_id);
CREATE INDEX IF NOT EXISTS idx_is_located_in_end ON ldbc_snb."IS_LOCATED_IN" (end_id);
CREATE INDEX IF NOT EXISTS idx_has_tag_start ON ldbc_snb."HAS_TAG" (start_id);
CREATE INDEX IF NOT EXISTS idx_has_tag_end ON ldbc_snb."HAS_TAG" (end_id);
CREATE INDEX IF NOT EXISTS idx_has_interest_start ON ldbc_snb."HAS_INTEREST" (start_id);
CREATE INDEX IF NOT EXISTS idx_has_interest_end ON ldbc_snb."HAS_INTEREST" (end_id);
CREATE INDEX IF NOT EXISTS idx_reply_of_start ON ldbc_snb."REPLY_OF" (start_id);
CREATE INDEX IF NOT EXISTS idx_reply_of_end ON ldbc_snb."REPLY_OF" (end_id);
CREATE INDEX IF NOT EXISTS idx_container_of_start ON ldbc_snb."CONTAINER_OF" (start_id);
CREATE INDEX IF NOT EXISTS idx_container_of_end ON ldbc_snb."CONTAINER_OF" (end_id);
CREATE INDEX IF NOT EXISTS idx_has_member_start ON ldbc_snb."HAS_MEMBER" (start_id);
CREATE INDEX IF NOT EXISTS idx_has_member_end ON ldbc_snb."HAS_MEMBER" (end_id);
CREATE INDEX IF NOT EXISTS idx_has_moderator_start ON ldbc_snb."HAS_MODERATOR" (start_id);
CREATE INDEX IF NOT EXISTS idx_has_moderator_end ON ldbc_snb."HAS_MODERATOR" (end_id);
CREATE INDEX IF NOT EXISTS idx_likes_start ON ldbc_snb."LIKES" (start_id);
CREATE INDEX IF NOT EXISTS idx_likes_end ON ldbc_snb."LIKES" (end_id);
CREATE INDEX IF NOT EXISTS idx_has_type_start ON ldbc_snb."HAS_TYPE" (start_id);
CREATE INDEX IF NOT EXISTS idx_has_type_end ON ldbc_snb."HAS_TYPE" (end_id);
CREATE INDEX IF NOT EXISTS idx_is_subclass_of_start ON ldbc_snb."IS_SUBCLASS_OF" (start_id);
CREATE INDEX IF NOT EXISTS idx_is_subclass_of_end ON ldbc_snb."IS_SUBCLASS_OF" (end_id);
CREATE INDEX IF NOT EXISTS idx_is_part_of_start ON ldbc_snb."IS_PART_OF" (start_id);
CREATE INDEX IF NOT EXISTS idx_is_part_of_end ON ldbc_snb."IS_PART_OF" (end_id);
CREATE INDEX IF NOT EXISTS idx_study_at_start ON ldbc_snb."STUDY_AT" (start_id);
CREATE INDEX IF NOT EXISTS idx_study_at_end ON ldbc_snb."STUDY_AT" (end_id);
CREATE INDEX IF NOT EXISTS idx_work_at_start ON ldbc_snb."WORK_AT" (start_id);
CREATE INDEX IF NOT EXISTS idx_work_at_end ON ldbc_snb."WORK_AT" (end_id);

-- Additional property indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_person_firstname ON ldbc_snb."Person" ((ag_catalog.agtype_access_operator(properties, '"firstName"')));
CREATE INDEX IF NOT EXISTS idx_tag_name ON ldbc_snb."Tag" ((ag_catalog.agtype_access_operator(properties, '"name"')));
CREATE INDEX IF NOT EXISTS idx_tagclass_name ON ldbc_snb."TagClass" ((ag_catalog.agtype_access_operator(properties, '"name"')));
CREATE INDEX IF NOT EXISTS idx_country_name ON ldbc_snb."Country" ((ag_catalog.agtype_access_operator(properties, '"name"')));
