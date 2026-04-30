SET search_path = ag_catalog, public;
SELECT tagName, postCount FROM cypher('$graphName', $$
  MATCH (knownTag:Tag {name: '$tagName'})
  WITH knownTag.id AS knownTagId
  MATCH (person:Person {id: $personId})-[:KNOWS*1..2]-(friend:Person)
  WHERE person <> friend
  WITH DISTINCT friend, knownTagId
  MATCH (friend)<-[:HAS_CREATOR]-(post:Post),
        (post)-[:HAS_TAG]->(t:Tag {id: knownTagId}),
        (post)-[:HAS_TAG]->(tag:Tag)
  WHERE t <> tag
  WITH tag.name AS tagName, count(post) AS postCount
  RETURN tagName, postCount
  ORDER BY postCount DESC, tagName ASC
  LIMIT 10
$$) AS (tagName agtype, postCount agtype)
