SET search_path = ag_catalog, public;
SELECT personId, personFirstName, personLastName, tagNames, replyCount
FROM cypher('$graphName', $$
  MATCH (baseTagClass:TagClass)
  WHERE baseTagClass.name = '$tagClassName'
  OPTIONAL MATCH (childTag:Tag)-[:HAS_TYPE]->(baseTagClass)
  OPTIONAL MATCH (subTag:Tag)-[:HAS_TYPE]->(:TagClass)-[:IS_SUBCLASS_OF*1..20]->(baseTagClass)
  WITH collect(DISTINCT childTag.id) + collect(DISTINCT subTag.id) AS tagIds
  MATCH (:Person {id: $personId})-[:KNOWS]-(friend:Person)<-[:HAS_CREATOR]-(comment:Comment)-[:REPLY_OF]->(:Post)-[:HAS_TAG]->(tag:Tag)
  WHERE tag.id IN tagIds
  RETURN
    friend.id AS personId,
    friend.firstName AS personFirstName,
    friend.lastName AS personLastName,
    collect(DISTINCT tag.name) AS tagNames,
    count(DISTINCT comment) AS replyCount
  ORDER BY replyCount DESC, friend.id ASC
  LIMIT 20
$$) AS (personId agtype, personFirstName agtype, personLastName agtype, tagNames agtype, replyCount agtype)
