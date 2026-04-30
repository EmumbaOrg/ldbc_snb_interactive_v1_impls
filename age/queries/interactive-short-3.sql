SET search_path = ag_catalog, public;
SELECT personId, firstName, lastName, friendshipCreationDate
FROM cypher('$graphName', $$
  MATCH (n:Person {id: $personId})-[r:KNOWS]-(friend:Person)
  RETURN
    friend.id AS personId,
    friend.firstName AS firstName,
    friend.lastName AS lastName,
    r.creationDate AS friendshipCreationDate
  ORDER BY friendshipCreationDate DESC, friend.id ASC
$$) AS (personId agtype, firstName agtype, lastName agtype, friendshipCreationDate agtype)
