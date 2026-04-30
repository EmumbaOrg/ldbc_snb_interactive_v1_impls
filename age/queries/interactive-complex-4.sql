SET search_path = ag_catalog, public;
SELECT tagName, postCount FROM cypher('$graphName', $$
  MATCH (person:Person {id: $personId})-[:KNOWS]-(friend:Person),
        (friend)<-[:HAS_CREATOR]-(post:Post)-[:HAS_TAG]->(tag:Tag)
  WITH DISTINCT tag, post
  WITH tag,
       CASE
         WHEN post.creationDate >= $startDate AND post.creationDate < $endDate THEN 1
         ELSE 0
       END AS valid,
       CASE
         WHEN post.creationDate < $startDate THEN 1
         ELSE 0
       END AS inValid
  WITH tag, sum(valid) AS postCount, sum(inValid) AS inValidPostCount
  WHERE postCount > 0 AND inValidPostCount = 0
  RETURN tag.name AS tagName, postCount
  ORDER BY postCount DESC, tagName ASC
  LIMIT 10
$$) AS (tagName agtype, postCount agtype)
