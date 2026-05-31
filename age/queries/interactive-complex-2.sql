-- LdbcQuery2 — Top-20 recent messages by direct friends (before maxDate).
-- Hybrid: Cypher fetches 1-hop friends + their recent messages (Comment + Post
-- UNION ALL arms — AGE has no polymorphic Message label, AGE-QUIRKS §3).
-- Outer SQL takes global top-20 by creationDate DESC, id ASC.
--
-- Milestone A 2026-05-30: MessageByCreator retired. Canonical Cypher shape.
-- Each arm does: MATCH (p)-[:KNOWS]->(friend) MATCH (friend)<-[:HAS_CREATOR]-(m:Type)
-- WHERE m.creationDate <= $maxDate RETURN ... ORDER BY creationDate DESC, id ASC LIMIT 20.
-- Inner LIMIT 20 per arm limits rows before outer sort (AGE still materialises fully,
-- but this caps the input for the outer top-20 correctly).
--
-- Date filter: `<= $maxDate` (NOT `<`) matches the Neo4j reference (cypher/queries/
-- interactive-complex-2.cypher: `message.creationDate <= $maxDate`).
--
-- messageContent is kept as agtype (NOT cast to ::text). AgeConverter.toStr unwraps
-- the outer JSON quotes of an agtype string before any trim.
--
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11; IU8 stores both directions.

WITH raw AS (
  SELECT
    (person_id::text)::bigint  AS person_id,
    fn::text                   AS first_name,
    ln::text                   AS last_name,
    (msg_id::text)::bigint     AS msg_id,
    content                    AS msg_content,
    (cdate::text)::bigint      AS cdate
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    MATCH (friend)<-[:HAS_CREATOR]-(m:Comment)
    WHERE m.creationDate <= $maxDate
    RETURN friend.id AS person_id, friend.firstName AS fn, friend.lastName AS ln,
           m.id AS msg_id, m.content AS content, m.creationDate AS cdate
    ORDER BY m.creationDate DESC, m.id ASC
    LIMIT 20
  $$) AS x(person_id agtype, fn agtype, ln agtype, msg_id agtype, content agtype, cdate agtype)
  UNION ALL
  SELECT
    (person_id::text)::bigint,
    fn::text,
    ln::text,
    (msg_id::text)::bigint,
    content,
    (cdate::text)::bigint
  FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    MATCH (friend)<-[:HAS_CREATOR]-(m:Post)
    WHERE m.creationDate <= $maxDate
    RETURN friend.id AS person_id, friend.firstName AS fn, friend.lastName AS ln,
           m.id AS msg_id,
           coalesce(m.content, m.imageFile) AS content,
           m.creationDate AS cdate
    ORDER BY m.creationDate DESC, m.id ASC
    LIMIT 20
  $$) AS y(person_id agtype, fn agtype, ln agtype, msg_id agtype, content agtype, cdate agtype)
)
SELECT
  person_id::ag_catalog.agtype                          AS personId,
  ag_catalog.text_to_agtype(first_name)                AS personFirstName,
  ag_catalog.text_to_agtype(last_name)                 AS personLastName,
  msg_id::ag_catalog.agtype                            AS messageId,
  msg_content                                          AS messageContent,
  cdate::ag_catalog.agtype                             AS messageCreationDate
FROM raw
ORDER BY cdate DESC, msg_id ASC
LIMIT 20;
