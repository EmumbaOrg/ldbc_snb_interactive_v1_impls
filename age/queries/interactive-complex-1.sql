SET search_path = ag_catalog, public;
SELECT * FROM (
  SELECT DISTINCT ON (friendId)
    friendId, friendLastName, distanceFromPerson, friendBirthday, friendCreationDate,
    friendGender, friendBrowserUsed, friendLocationIp, friendEmails, friendLanguages,
    friendCityName, friendUniversities, friendCompanies
  FROM (
  -- Distance 1
  SELECT friendId, friendLastName, distanceFromPerson, friendBirthday, friendCreationDate,
         friendGender, friendBrowserUsed, friendLocationIp, friendEmails, friendLanguages,
         friendCityName, friendUniversities, friendCompanies
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]-(friend:Person)
    WHERE friend.firstName = '$firstName' AND p <> friend
    MATCH (friend)-[:IS_LOCATED_IN]->(friendCity:City)
    OPTIONAL MATCH (friend)-[sa:STUDY_AT]->(uni:University)
    WITH friend, friendCity, collect(
      CASE WHEN uni IS NOT NULL THEN [uni.name, sa.classYear, uni.placeName] ELSE NULL END
    ) AS friendUniversities
    OPTIONAL MATCH (friend)-[wa:WORK_AT]->(comp:Company)
    WITH friend, friendCity, friendUniversities, collect(
      CASE WHEN comp IS NOT NULL THEN [comp.name, wa.workFrom, comp.placeName] ELSE NULL END
    ) AS friendCompanies
    RETURN
      friend.id AS friendId,
      friend.lastName AS friendLastName,
      1 AS distanceFromPerson,
      friend.birthday AS friendBirthday,
      friend.creationDate AS friendCreationDate,
      friend.gender AS friendGender,
      friend.browserUsed AS friendBrowserUsed,
      friend.locationIP AS friendLocationIp,
      friend.email AS friendEmails,
      friend.speaks AS friendLanguages,
      friendCity.name AS friendCityName,
      friendUniversities,
      friendCompanies
  $$) AS (friendId agtype, friendLastName agtype, distanceFromPerson agtype, friendBirthday agtype,
          friendCreationDate agtype, friendGender agtype, friendBrowserUsed agtype, friendLocationIp agtype,
          friendEmails agtype, friendLanguages agtype, friendCityName agtype, friendUniversities agtype,
          friendCompanies agtype)

  UNION ALL

  -- Distance 2
  SELECT friendId, friendLastName, distanceFromPerson, friendBirthday, friendCreationDate,
         friendGender, friendBrowserUsed, friendLocationIp, friendEmails, friendLanguages,
         friendCityName, friendUniversities, friendCompanies
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]-(:Person)-[:KNOWS]-(friend:Person)
    WHERE friend.firstName = '$firstName' AND p <> friend
    MATCH (friend)-[:IS_LOCATED_IN]->(friendCity:City)
    OPTIONAL MATCH (friend)-[sa:STUDY_AT]->(uni:University)
    WITH friend, friendCity, collect(
      CASE WHEN uni IS NOT NULL THEN [uni.name, sa.classYear, uni.placeName] ELSE NULL END
    ) AS friendUniversities
    OPTIONAL MATCH (friend)-[wa:WORK_AT]->(comp:Company)
    WITH friend, friendCity, friendUniversities, collect(
      CASE WHEN comp IS NOT NULL THEN [comp.name, wa.workFrom, comp.placeName] ELSE NULL END
    ) AS friendCompanies
    RETURN
      friend.id AS friendId,
      friend.lastName AS friendLastName,
      2 AS distanceFromPerson,
      friend.birthday AS friendBirthday,
      friend.creationDate AS friendCreationDate,
      friend.gender AS friendGender,
      friend.browserUsed AS friendBrowserUsed,
      friend.locationIP AS friendLocationIp,
      friend.email AS friendEmails,
      friend.speaks AS friendLanguages,
      friendCity.name AS friendCityName,
      friendUniversities,
      friendCompanies
  $$) AS (friendId agtype, friendLastName agtype, distanceFromPerson agtype, friendBirthday agtype,
          friendCreationDate agtype, friendGender agtype, friendBrowserUsed agtype, friendLocationIp agtype,
          friendEmails agtype, friendLanguages agtype, friendCityName agtype, friendUniversities agtype,
          friendCompanies agtype)

  UNION ALL

  -- Distance 3
  SELECT friendId, friendLastName, distanceFromPerson, friendBirthday, friendCreationDate,
         friendGender, friendBrowserUsed, friendLocationIp, friendEmails, friendLanguages,
         friendCityName, friendUniversities, friendCompanies
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]-(:Person)-[:KNOWS]-(:Person)-[:KNOWS]-(friend:Person)
    WHERE friend.firstName = '$firstName' AND p <> friend
    MATCH (friend)-[:IS_LOCATED_IN]->(friendCity:City)
    OPTIONAL MATCH (friend)-[sa:STUDY_AT]->(uni:University)
    WITH friend, friendCity, collect(
      CASE WHEN uni IS NOT NULL THEN [uni.name, sa.classYear, uni.placeName] ELSE NULL END
    ) AS friendUniversities
    OPTIONAL MATCH (friend)-[wa:WORK_AT]->(comp:Company)
    WITH friend, friendCity, friendUniversities, collect(
      CASE WHEN comp IS NOT NULL THEN [comp.name, wa.workFrom, comp.placeName] ELSE NULL END
    ) AS friendCompanies
    RETURN
      friend.id AS friendId,
      friend.lastName AS friendLastName,
      3 AS distanceFromPerson,
      friend.birthday AS friendBirthday,
      friend.creationDate AS friendCreationDate,
      friend.gender AS friendGender,
      friend.browserUsed AS friendBrowserUsed,
      friend.locationIP AS friendLocationIp,
      friend.email AS friendEmails,
      friend.speaks AS friendLanguages,
      friendCity.name AS friendCityName,
      friendUniversities,
      friendCompanies
  $$) AS (friendId agtype, friendLastName agtype, distanceFromPerson agtype, friendBirthday agtype,
          friendCreationDate agtype, friendGender agtype, friendBrowserUsed agtype, friendLocationIp agtype,
          friendEmails agtype, friendLanguages agtype, friendCityName agtype, friendUniversities agtype,
          friendCompanies agtype)
  ) raw
  ORDER BY friendId, distanceFromPerson ASC
) deduped
ORDER BY distanceFromPerson ASC, friendLastName ASC, friendId ASC
LIMIT 20
