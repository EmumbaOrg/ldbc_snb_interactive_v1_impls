SET search_path = ag_catalog, public;
SELECT forumId, forumTitle, moderatorId, moderatorFirstName, moderatorLastName
FROM (
  SELECT 1 AS src, * FROM cypher('$graphName', $$
    MATCH (m:Comment {id: $messageId})-[:REPLY_OF]->(r1)
    OPTIONAL MATCH (r1)-[:REPLY_OF]->(r2)
    OPTIONAL MATCH (r2)-[:REPLY_OF]->(r3)
    OPTIONAL MATCH (r3)-[:REPLY_OF]->(r4)
    OPTIONAL MATCH (r4)-[:REPLY_OF]->(r5)
    OPTIONAL MATCH (r5)-[:REPLY_OF]->(r6)
    OPTIONAL MATCH (r6)-[:REPLY_OF]->(r7)
    OPTIONAL MATCH (r7)-[:REPLY_OF]->(r8)
    WITH coalesce(r8, r7, r6, r5, r4, r3, r2, r1) AS rootPost
    MATCH (p:Post)<-[:CONTAINER_OF]-(forum:Forum)-[:HAS_MODERATOR]->(mod:Person)
    WHERE id(p) = id(rootPost)
    RETURN forum.id, forum.title, mod.id, mod.firstName, mod.lastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype,
          moderatorFirstName agtype, moderatorLastName agtype)
  UNION ALL
  SELECT 2 AS src, * FROM cypher('$graphName', $$
    MATCH (post:Post {id: $messageId})<-[:CONTAINER_OF]-(forum:Forum)-[:HAS_MODERATOR]->(mod:Person)
    RETURN forum.id, forum.title, mod.id, mod.firstName, mod.lastName
  $$) AS (forumId agtype, forumTitle agtype, moderatorId agtype,
          moderatorFirstName agtype, moderatorLastName agtype)
) forum
ORDER BY src
LIMIT 1;
