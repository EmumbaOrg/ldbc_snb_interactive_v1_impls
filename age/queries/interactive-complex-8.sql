-- LdbcQuery8 — Recent replies to any of the user's messages, with author info.
-- Pure Cypher: single call walks HAS_CREATOR ← message ← REPLY_OF ← Comment → HAS_CREATOR → author.
-- Untyped `message` intermediate causes AGE to plan as UNION over labels internally (AGE-QUIRKS §3),
-- but cost is bounded to the seed Person's messages so no seq-scan risk. No variable-length path
-- (AGE-QUIRKS §4 does not apply). ORDER+LIMIT inside the Cypher block is a final RETURN — safe.

SELECT * FROM cypher('$graphName', $$
  MATCH (start:Person {id: $personId})<-[:HAS_CREATOR]-(message)
        <-[:REPLY_OF]-(reply:Comment)-[:HAS_CREATOR]->(author:Person)
  RETURN author.id, author.firstName, author.lastName,
         reply.creationDate, reply.id, reply.content
  ORDER BY reply.creationDate DESC, reply.id ASC
  LIMIT 20
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        commentCreationDate agtype, commentId agtype, commentContent agtype);
