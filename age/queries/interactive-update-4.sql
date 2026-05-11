-- LdbcUpdate4AddForum — also maintains Forum.moderator_id denorm column.
SELECT * FROM cypher('$graphName', $$
  MATCH (mod:Person {id: $moderatorPersonId})
  CREATE (f:Forum {id: $forumId, title: $forumTitle, creationDate: $creationDate})-[:HAS_MODERATOR]->(mod)
  WITH f
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (f)-[:HAS_TAG]->(t)
  RETURN count(f)
$$) AS (result agtype);
UPDATE ldbc_snb."Forum" f
   SET moderator_id = (SELECT end_id FROM ldbc_snb."HAS_MODERATOR" WHERE start_id = f.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(f.properties, 'id') AS bigint) = $forumId
;
