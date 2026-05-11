-- LdbcUpdate6AddPost — create a Post vertex with HAS_CREATOR/CONTAINER_OF/IS_LOCATED_IN/HAS_TAG edges.
-- Hybrid: Cypher block creates Post + all edges in one chained WITH/UNWIND block.
-- SQL UPDATE/INSERT maintains:
--   Post.{creator_id, forum_id, country_id}     (iter-1 column denorm)
--   ForumMemberPostCount(forum_id, member_id)   (iter-2 aggregate)
--   PersonPostCount(person_id)                  (iter-2 aggregate)
SELECT * FROM cypher('$graphName', $$
  MATCH (author:Person {id: $authorPersonId}),
        (country:Country {id: $countryId}),
        (forum:Forum {id: $forumId})
  CREATE (post:Post {
    id: $postId,
    creationDate: $creationDate,
    locationIP: $locationIP,
    browserUsed: $browserUsed,
    language: $language,
    content: CASE $content WHEN '' THEN null ELSE $content END,
    imageFile: CASE $imageFile WHEN '' THEN null ELSE $imageFile END,
    length: $length
  })-[:HAS_CREATOR]->(author),
  (forum)-[:CONTAINER_OF]->(post),
  (post)-[:IS_LOCATED_IN]->(country)
  WITH post
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (post)-[:HAS_TAG]->(t)
  RETURN count(post)
$$) AS (result agtype);
UPDATE ldbc_snb."Post" p
   SET creator_id = (SELECT end_id FROM ldbc_snb."HAS_CREATOR" WHERE start_id = p.id LIMIT 1),
       forum_id   = (SELECT start_id FROM ldbc_snb."CONTAINER_OF" WHERE end_id = p.id LIMIT 1),
       country_id = (SELECT end_id FROM ldbc_snb."IS_LOCATED_IN" WHERE start_id = p.id LIMIT 1)
 WHERE CAST(ag_catalog.agtype_object_field_text(p.properties, 'id') AS bigint) = $postId
;
-- Aggregate INSERTs: SELECT DISTINCT ... LIMIT 1 guards against pre-existing
-- duplicate label rows (e.g. data has a Forum with the same business id
-- twice — would otherwise cause the Cypher block CREATE to fan-out and produce
-- duplicate Posts, which would then violate ON CONFLICT). The single
-- (forum_id, creator_id) tuple is what we want to record either way.
INSERT INTO ldbc_snb."ForumMemberPostCount" (forum_id, member_id, post_count)
SELECT forum_id, creator_id, 1 FROM (
  SELECT DISTINCT p.forum_id, p.creator_id
    FROM ldbc_snb."Post" p
   WHERE CAST(ag_catalog.agtype_object_field_text(p.properties, 'id') AS bigint) = $postId
     AND p.forum_id IS NOT NULL
     AND p.creator_id IS NOT NULL
   LIMIT 1
) ins
ON CONFLICT (forum_id, member_id) DO UPDATE
   SET post_count = ldbc_snb."ForumMemberPostCount".post_count + 1
;
INSERT INTO ldbc_snb."PersonPostCount" (person_id, post_count)
SELECT creator_id, 1 FROM (
  SELECT DISTINCT p.creator_id
    FROM ldbc_snb."Post" p
   WHERE CAST(ag_catalog.agtype_object_field_text(p.properties, 'id') AS bigint) = $postId
     AND p.creator_id IS NOT NULL
   LIMIT 1
) ins
ON CONFLICT (person_id) DO UPDATE
   SET post_count = ldbc_snb."PersonPostCount".post_count + 1
;
