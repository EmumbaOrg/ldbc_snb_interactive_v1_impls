SET search_path = ag_catalog, public;
SELECT personId, personFirstName, personLastName, commonInterestScore, personGender, personCityName
FROM (
  SELECT personId, personFirstName, personLastName, personGender, personCityName,
         commonPostCount, postCount,
         (commonPostCount - (postCount - commonPostCount))::int AS commonInterestScore,
         personBirthday
  FROM (
    SELECT personId, personFirstName, personLastName, personGender, personCityName,
           personBirthday,
           SUM(isCommon::text::int) AS commonPostCount,
           COUNT(*) AS postCount
    FROM cypher('$graphName', $$
      MATCH (person:Person {id: $personId})-[:KNOWS]-(:Person)-[:KNOWS]-(friend:Person)
      WHERE person <> friend
      OPTIONAL MATCH (person)-[k:KNOWS]-(friend)
      WITH friend, person, k WHERE k IS NULL
      WITH DISTINCT friend, person
      MATCH (friend)-[:IS_LOCATED_IN]->(city:City)
      MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
      OPTIONAL MATCH (post)-[:HAS_TAG]->(tag:Tag)<-[:HAS_INTEREST]-(person)
      RETURN
        friend.id AS personId,
        friend.firstName AS personFirstName,
        friend.lastName AS personLastName,
        friend.gender AS personGender,
        city.name AS personCityName,
        friend.birthday AS personBirthday,
        post.id AS postId,
        CASE WHEN tag IS NOT NULL THEN 1 ELSE 0 END AS isCommon
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            personGender agtype, personCityName agtype, personBirthday agtype,
            postId agtype, isCommon agtype)
    GROUP BY personId, personFirstName, personLastName, personGender, personCityName, personBirthday
  ) counted
) scored
WHERE
  (EXTRACT(MONTH FROM TO_TIMESTAMP(personBirthday::text::bigint / 1000.0)) = $month
   AND EXTRACT(DAY FROM TO_TIMESTAMP(personBirthday::text::bigint / 1000.0)) >= 21)
  OR
  (EXTRACT(MONTH FROM TO_TIMESTAMP(personBirthday::text::bigint / 1000.0)) = ($month % 12) + 1
   AND EXTRACT(DAY FROM TO_TIMESTAMP(personBirthday::text::bigint / 1000.0)) < 22)
ORDER BY commonInterestScore DESC, personId ASC
LIMIT 10
