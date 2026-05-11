-- LdbcQuery8 — Recent replies (V3 — Cypher-only, idiomatic 1-hop)
--
-- V2 did the whole query as SQL JOINs on Comment.reply_of_id and creator_id
-- (denorm columns). The denorm made it fast (~470 ms at SF3), but the query
-- no longer expressed any graph navigation — it was pure relational.
--
-- V3 restores the idiomatic Cypher form. The 1-hop reply pattern is safe:
--   - No variable-length path (no AGE-QUIRKS §4 risk).
--   - The untyped `message` intermediate (both Post and Comment can be replied
--     to) causes AGE 1.6 to plan this as UNION over labels — but the seed is
--     pinned to a single Person, so cost is bounded to that person's messages.
--   - AGE's HAS_CREATOR and REPLY_OF native indexes hash-probe directly.
--   - The fixed ~150 ms Cypher per-call overhead is acceptable for an
--     SF1000 budget of < 1 s (was ~470 ms SQL; regression accepted for
--     graph-identity restoration).
--
-- SF3 budget: < 1 s mean. SF1000 budget: < 1 s mean.

SELECT * FROM cypher('$graphName', $$
  MATCH (start:Person {id: $personId})<-[:HAS_CREATOR]-(message)
        <-[:REPLY_OF]-(reply:Comment)-[:HAS_CREATOR]->(author:Person)
  RETURN author.id, author.firstName, author.lastName,
         reply.creationDate, reply.id, reply.content
  ORDER BY reply.creationDate DESC, reply.id ASC
  LIMIT 20
$$) AS (personId agtype, personFirstName agtype, personLastName agtype,
        commentCreationDate agtype, commentId agtype, commentContent agtype);
