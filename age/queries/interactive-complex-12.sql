SELECT * FROM cypher('$graphName', $$
  MATCH (base:TagClass {name: $tagClassName})
  WITH base, id(base) AS baseId
  OPTIONAL MATCH (d1:TagClass)-[:IS_SUBCLASS_OF]->(base)
  OPTIONAL MATCH (d2:TagClass)-[:IS_SUBCLASS_OF]->(d1)
  OPTIONAL MATCH (d3:TagClass)-[:IS_SUBCLASS_OF]->(d2)
  OPTIONAL MATCH (d4:TagClass)-[:IS_SUBCLASS_OF]->(d3)
  OPTIONAL MATCH (d5:TagClass)-[:IS_SUBCLASS_OF]->(d4)
  OPTIONAL MATCH (d6:TagClass)-[:IS_SUBCLASS_OF]->(d5)
  WITH baseId, collect(DISTINCT id(d1)) + collect(DISTINCT id(d2)) + collect(DISTINCT id(d3))
     + collect(DISTINCT id(d4)) + collect(DISTINCT id(d5)) + collect(DISTINCT id(d6))
     + [baseId] AS validClassIds
  MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
  MATCH (friend)<-[:HAS_CREATOR]-(reply:Comment)-[:REPLY_OF]->(post:Post)
  MATCH (post)-[:HAS_TAG]->(tag:Tag)-[:HAS_TYPE]->(tc:TagClass)
  WHERE id(tc) IN validClassIds
  WITH friend, collect(DISTINCT tag.name) AS tagNames, count(DISTINCT reply) AS replyCount
  RETURN friend.id, friend.firstName, friend.lastName, tagNames, replyCount
  ORDER BY replyCount DESC, toInteger(friend.id) ASC
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        tagNames agtype, replyCount agtype)
LIMIT 20;
