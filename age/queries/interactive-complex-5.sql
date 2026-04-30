SET search_path = ag_catalog, public;
SELECT forumTitle, postCount FROM cypher('$graphName', $$
  MATCH (person:Person {id: $personId})-[:KNOWS*1..2]-(friend:Person)
  WHERE person <> friend
  WITH DISTINCT friend
  MATCH (friend)<-[membership:HAS_MEMBER]-(forum:Forum)
  WHERE membership.joinDate > $minDate
  OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)<-[:CONTAINER_OF]-(forum)
  RETURN
    forum.title AS forumTitle,
    forum.id AS forumId,
    count(post) AS postCount
  ORDER BY postCount DESC, forumId ASC
  LIMIT 20
$$) AS (forumTitle agtype, forumId agtype, postCount agtype)
