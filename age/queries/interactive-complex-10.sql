SELECT * FROM cypher('$graphName', $$
  MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)-[:IS_LOCATED_IN]->(city:City)
  WHERE friend.id <> $personId
  OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
  WITH p, friend, city, direct
  WHERE direct IS NULL
    AND ((friend.birthMonth = $month AND friend.birthDay >= 21)
      OR (friend.birthMonth = ($month % 12) + 1 AND friend.birthDay < 22))
  WITH DISTINCT p, friend, city
  OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
  WITH p, friend, city, count(DISTINCT post) AS postCount
  OPTIONAL MATCH (friend)<-[:HAS_CREATOR]-(commonPost:Post)-[:HAS_TAG]->(:Tag)<-[:HAS_INTEREST]-(p)
  WITH friend, city, postCount, count(DISTINCT commonPost) AS commonPostCount
  WITH friend, city, commonPostCount - (postCount - commonPostCount) AS commonInterestScore
  RETURN friend.id, friend.firstName, friend.lastName,
         commonInterestScore, friend.gender, city.name
  ORDER BY commonInterestScore DESC, friend.id ASC
  LIMIT 10
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        commonInterestScore agtype, personGender agtype, personCityName agtype);
