-- LdbcUpdate4AddForum — create a Forum vertex with HAS_MODERATOR + HAS_TAG edges,
-- and mirror its identity/title into the ForumSide side table for IC5.
--
-- AGENTS.md §14 compliance: outer SQL only touches the non-AGE side table
-- ForumSide. All graph mutations and AGE-table reads happen inside Cypher.
--
-- Two Cypher calls:
--   1. CREATE the Forum + HAS_MODERATOR + HAS_TAG edges.
--   2. MATCH the just-created Forum to recover id(f), business_id, and title.
--      Cannot be merged with call 1: when $tagIds is empty the UNWIND folds
--      away the row carrying f forward into RETURN, leaving no row to feed
--      the INSERT. Two-step is the established AGE workaround.
--
-- The title is pulled out of the Forum vertex via the second Cypher call
-- rather than via SQL substitution of $forumTitle. The driver's convertString
-- emits Cypher-style backslash escaping ('O\'Brien''s club') which is correct
-- inside the Cypher CREATE but invalid in a SQL VALUES clause — any title
-- containing an apostrophe would have broken the SQL parse. The Cypher path
-- handles escaping correctly.
--
-- The legacy Forum.moderator_id denorm UPDATE has been removed: nothing reads
-- that column (only IU4 wrote it). Reintroducing moderator on the read path
-- should add it to ForumSide rather than writing back to the AGE label table.

SELECT * FROM cypher('$graphName', $$
  MATCH (mod:Person {id: $moderatorPersonId})
  CREATE (f:Forum {id: $forumId, title: $forumTitle, creationDate: $creationDate})-[:HAS_MODERATOR]->(mod)
  WITH f
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (f)-[:HAS_TAG]->(t)
  RETURN count(f)
$$) AS (result agtype);

INSERT INTO ldbc_snb."ForumSide" (forum_id, forum_business_id, title)
SELECT
  (forum_gid::text)::ag_catalog.graphid,
  (biz_id::text)::bigint,
  title_agt::text
FROM cypher('$graphName', $$
  MATCH (f:Forum {id: $forumId})
  RETURN id(f) AS forum_gid, f.id AS biz_id, f.title AS title_agt
$$) AS (forum_gid agtype, biz_id agtype, title_agt agtype)
ON CONFLICT (forum_id) DO NOTHING;
