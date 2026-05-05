SET search_path = ag_catalog, public;
SELECT * FROM cypher('$graphName', $$
  MATCH (base:TagClass {name: $tagClassName})
  MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
  MATCH (friend)<-[:HAS_CREATOR]-(reply:Comment)-[:REPLY_OF]->(post:Post)
  MATCH (post)-[:HAS_TAG]->(tag:Tag)-[:HAS_TYPE]->(tc:TagClass)
  OPTIONAL MATCH (tc)-[:IS_SUBCLASS_OF]->(s1:TagClass)
  OPTIONAL MATCH (s1)-[:IS_SUBCLASS_OF]->(s2:TagClass)
  OPTIONAL MATCH (s2)-[:IS_SUBCLASS_OF]->(s3:TagClass)
  OPTIONAL MATCH (s3)-[:IS_SUBCLASS_OF]->(s4:TagClass)
  OPTIONAL MATCH (s4)-[:IS_SUBCLASS_OF]->(s5:TagClass)
  OPTIONAL MATCH (s5)-[:IS_SUBCLASS_OF]->(s6:TagClass)
  WITH friend, reply, tag, base, tc, s1, s2, s3, s4, s5, s6
  WHERE id(tc) = id(base)
     OR id(s1) = id(base)
     OR id(s2) = id(base)
     OR id(s3) = id(base)
     OR id(s4) = id(base)
     OR id(s5) = id(base)
     OR id(s6) = id(base)
  WITH friend, collect(DISTINCT tag.name) AS tagNames, count(DISTINCT reply) AS replyCount
  RETURN friend.id, friend.firstName, friend.lastName, tagNames, replyCount
  ORDER BY replyCount DESC, toInteger(friend.id) ASC
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        tagNames agtype, replyCount agtype)
LIMIT 20;
