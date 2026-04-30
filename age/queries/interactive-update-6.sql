SET search_path = ag_catalog, public;
SELECT * FROM cypher('$graphName', $$
  MATCH (author:Person {id: $authorPersonId}), (country:Country {id: $countryId}), (forum:Forum {id: $forumId})
  CREATE (author)<-[:HAS_CREATOR]-(p:Post {
    id: $postId,
    creationDate: $creationDate,
    locationIP: '$locationIP',
    browserUsed: '$browserUsed',
    language: '$language',
    content: '$content',
    imageFile: '$imageFile',
    length: $length
  })<-[:CONTAINER_OF]-(forum)
  CREATE (p)-[:IS_LOCATED_IN]->(country)
  WITH p
  UNWIND $tagIds AS tagId
    MATCH (t:Tag {id: tagId})
    CREATE (p)-[:HAS_TAG]->(t)
  RETURN p.id AS result
$$) AS (result agtype)
