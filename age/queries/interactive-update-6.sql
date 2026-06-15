-- LdbcUpdate6AddPost — create a Post vertex with HAS_CREATOR/CONTAINER_OF/IS_LOCATED_IN/HAS_TAG edges.
-- Cypher-only: single CREATE + UNWIND call. No side tables maintained.

-- Call 1: CREATE Post + edges. count(*) always returns exactly 1 row.
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
  RETURN count(*)
$$) AS (result agtype);

