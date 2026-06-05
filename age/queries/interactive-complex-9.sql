-- LdbcQuery9 — Top-20 recent messages (before maxDate) by 1+2-hop friends.
-- Hybrid: four Cypher arms (1-hop Comments, 1-hop Posts, 2-hop Comments,
-- 2-hop Posts) each traverse friends then messages. Outer SQL UNION ALL,
-- deduplicates by message id (friends reachable by both 1-hop and 2-hop
-- must not appear twice), then takes global top-20.
--
-- Four arms needed because: (a) AGE has no polymorphic Message label
-- (AGE-QUIRKS §3); (b) friend de-dup requires UNION (set-dedup) over
-- 1-hop ∪ 2-hop, but a LIMIT inside a Cypher UNION is unsupported in AGE
-- (AGE-QUIRKS §1 / CLAUDE.md unsupported list). Shape per arm:
--   MATCH (p)-[:KNOWS]->{1|1..2}->(friend) WHERE friend.id <> $personId
--   MATCH (friend)<-[:HAS_CREATOR]-(m:{Comment|Post})
--   WHERE m.creationDate < $maxDate
--   RETURN friend.id, friend.firstName, friend.lastName, m.id, content, m.creationDate
--   ORDER BY m.creationDate DESC, m.id ASC LIMIT 20
-- Dedup on message_id in outer SQL (a message has exactly one creator).
--
-- Per-arm `ORDER BY ... LIMIT 20` (single-query LIMIT, not
-- a Cypher-UNION LIMIT, so supported) is mandatory, not an optimization.
-- AGE #1000: cypher() materializes its entire match set in backend memory
-- before the outer SQL can apply LIMIT. For a high-degree person the 2-hop arm
-- expands to ~2.5M (friend,message) rows; crossing all of them (with content
-- text) into the SQL UNION OOM-kills the backend (signal 9, confirmed SF3
-- persons 28587302332608 / 17592186047812 / 6597069786375). With the per-arm
-- LIMIT the sort stays inside the Cypher executor (spills via work_mem) and only
-- 20 rows per arm cross the boundary; the three crashers now complete in ~27-29s.
-- CORRECTNESS: global top-20 ⊆ union of each arm's top-20 — a message in the
-- global top-20 has ≤19 newer messages overall, hence ≤19 newer within its own
-- arm (a subset), so it survives that arm's LIMIT 20. Outer SQL re-sorts the
-- ≤80 unioned rows and takes the global top-20. The slow ~27s latency still
-- surfaces #1000; the LIMIT only prevents the crash, it does not hide the cost.
-- The per-arm `WITH DISTINCT friend` is MANDATORY, not cosmetic: a 2-hop friend
-- reachable via K intermediaries yields K duplicate rows per message, and those
-- duplicates would consume the LIMIT-20 slots BEFORE the outer dedup, dropping
-- genuinely-newer messages. (Same path-multiplicity trap as IC5.) Verified at
-- SF3: plain (no LIMIT) and DISTINCT+LIMIT hash-match; LIMIT-without-DISTINCT
-- diverges. The old no-LIMIT form deduped before any LIMIT so was immune.
--
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11; IU8 stores both directions.
-- messageContent: kept as agtype — AgeConverter.toStr unwraps outer JSON quotes.

WITH raw AS (
  -- 1-hop friends, Comments
  SELECT
    (person_id::text)::bigint AS person_id,
    fn::text                  AS first_name,
    ln::text                  AS last_name,
    (msg_id::text)::bigint    AS msg_id,
    content                   AS msg_content,
    (cdate::text)::bigint     AS cdate
  FROM ag_catalog.cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH DISTINCT friend
    MATCH (friend)<-[:HAS_CREATOR]-(m:Comment)
    WHERE m.creationDate < $maxDate
    RETURN friend.id AS person_id, friend.firstName AS fn, friend.lastName AS ln,
           m.id AS msg_id, m.content AS content, m.creationDate AS cdate
    ORDER BY m.creationDate DESC, m.id ASC
    LIMIT 20
  $$) AS x(person_id agtype, fn agtype, ln agtype, msg_id agtype, content agtype, cdate agtype)
  UNION ALL
  -- 1-hop friends, Posts
  SELECT
    (person_id::text)::bigint,
    fn::text,
    ln::text,
    (msg_id::text)::bigint,
    content,
    (cdate::text)::bigint
  FROM ag_catalog.cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH DISTINCT friend
    MATCH (friend)<-[:HAS_CREATOR]-(m:Post)
    WHERE m.creationDate < $maxDate
    RETURN friend.id AS person_id, friend.firstName AS fn, friend.lastName AS ln,
           m.id AS msg_id, coalesce(m.content, m.imageFile) AS content,
           m.creationDate AS cdate
    ORDER BY m.creationDate DESC, m.id ASC
    LIMIT 20
  $$) AS y(person_id agtype, fn agtype, ln agtype, msg_id agtype, content agtype, cdate agtype)
  UNION ALL
  -- 2-hop friends, Comments
  SELECT
    (person_id::text)::bigint,
    fn::text,
    ln::text,
    (msg_id::text)::bigint,
    content,
    (cdate::text)::bigint
  FROM ag_catalog.cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH DISTINCT friend
    MATCH (friend)<-[:HAS_CREATOR]-(m:Comment)
    WHERE m.creationDate < $maxDate
    RETURN friend.id AS person_id, friend.firstName AS fn, friend.lastName AS ln,
           m.id AS msg_id, m.content AS content, m.creationDate AS cdate
    ORDER BY m.creationDate DESC, m.id ASC
    LIMIT 20
  $$) AS a(person_id agtype, fn agtype, ln agtype, msg_id agtype, content agtype, cdate agtype)
  UNION ALL
  -- 2-hop friends, Posts
  SELECT
    (person_id::text)::bigint,
    fn::text,
    ln::text,
    (msg_id::text)::bigint,
    content,
    (cdate::text)::bigint
  FROM ag_catalog.cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH DISTINCT friend
    MATCH (friend)<-[:HAS_CREATOR]-(m:Post)
    WHERE m.creationDate < $maxDate
    RETURN friend.id AS person_id, friend.firstName AS fn, friend.lastName AS ln,
           m.id AS msg_id, coalesce(m.content, m.imageFile) AS content,
           m.creationDate AS cdate
    ORDER BY m.creationDate DESC, m.id ASC
    LIMIT 20
  $$) AS b(person_id agtype, fn agtype, ln agtype, msg_id agtype, content agtype, cdate agtype)
),
-- De-duplicate: a message has exactly one creator, so msg_id uniquely
-- identifies a row. Friends reachable by both 1-hop and 2-hop would
-- otherwise produce duplicate rows for each message.
deduped AS (
  SELECT DISTINCT ON (msg_id)
    person_id, first_name, last_name, msg_id, msg_content, cdate
  FROM raw
  ORDER BY msg_id
)
SELECT
  person_id::ag_catalog.agtype                         AS personId,
  ag_catalog.text_to_agtype(first_name)               AS personFirstName,
  ag_catalog.text_to_agtype(last_name)                AS personLastName,
  msg_id::ag_catalog.agtype                           AS messageId,
  msg_content                                         AS messageContent,
  cdate::ag_catalog.agtype                            AS messageCreationDate
FROM deduped
ORDER BY cdate DESC, msg_id ASC
LIMIT 20;
