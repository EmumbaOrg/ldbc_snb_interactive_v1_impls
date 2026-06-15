-- Post-load finalize: ANALYZE the core tables. Runs after Step 3
-- (create-indexes) and before pg_dump in load-data.sh.
--
-- load-data.sh deliberately omits a full Step 4 VACUUM ANALYZE (a fresh load
-- has zero dead tuples, so VACUUM reclaims nothing) and relies on the targeted
-- ANALYZE below to give the planner stats before the snapshot is dumped.

SET search_path = ldbc_snb, ag_catalog, public;

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
