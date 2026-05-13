-- LdbcUpdate4AddForum — create a Forum vertex with HAS_MODERATOR + HAS_TAG edges.
-- Hybrid: original Cypher block creates the graph state; a second Cypher
-- lookup yields the new Forum's graphid which the outer INSERT mirrors into
-- ForumSide so IC5 can read forum titles without touching the AGE Forum table.
--
-- Three statements:
--   1. Cypher: create Forum + HAS_MODERATOR + HAS_TAGs (unchanged from before).
--   2. INSERT into ForumSide using a second Cypher MATCH to recover id(f)
--      after the create. (Doing this via an INSERT...SELECT FROM the same
--      Cypher block fails when $tagIds is empty: the UNWIND folds away the
--      row that would have carried id(f) into the SELECT.)
--   3. Legacy moderator_id denorm on the AGE Forum table. This itself
--      violates the directive and is tracked for separate migration to a
--      side-table approach (audit 2026-05-13).

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
SELECT (forum_gid::text)::ag_catalog.graphid,
       $forumId,
       $forumTitle::text
FROM cypher('$graphName', $$
  MATCH (f:Forum {id: $forumId})
  RETURN id(f) AS forum_gid
$$) AS (forum_gid agtype)
ON CONFLICT (forum_id) DO NOTHING;

UPDATE ldbc_snb."Forum" f
   SET moderator_id = (SELECT end_id FROM ldbc_snb."HAS_MODERATOR" WHERE start_id = f.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(f.properties, 'id') AS bigint) = $forumId
;
