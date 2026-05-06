SELECT tagName, postCount FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)<-[:HAS_CREATOR]-(post:Post)-[:HAS_TAG]->(tag:Tag)
    WITH DISTINCT tag, post
    WITH tag,
         CASE WHEN post.creationDate >= $startDate AND post.creationDate < $endDate THEN 1 ELSE 0 END AS inWindow,
         CASE WHEN post.creationDate < $startDate THEN 1 ELSE 0 END AS preWindow
    WITH tag, sum(inWindow) AS postCount, sum(preWindow) AS preWindowCount
    WHERE postCount > 0 AND preWindowCount = 0
    RETURN tag.name, postCount
    ORDER BY postCount DESC, tag.name ASC
  $$) AS (tagName agtype, postCount agtype)
) tags
ORDER BY postCount DESC, tagName ASC
LIMIT 10;
