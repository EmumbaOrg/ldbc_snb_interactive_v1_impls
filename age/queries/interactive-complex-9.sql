-- LdbcQuery9 — Top-20 recent messages (before maxDate) by friends + FoF.
-- Hybrid: Cypher block enumerates 1+2-hop friend ids (LDBC business bigints)
-- AND projects friend.firstName/lastName directly (Phase A: PersonSide retired).
-- Outer SQL walks ldbc_snb."MessageByCreator" per-friend in date-DESC order
-- with LATERAL LIMIT 20, then takes global top-20. CLAUDE.md §14 compliant —
-- outer SQL never touches AGE label tables; MessageByCreator is a non-AGE
-- side table maintained by the load step + IU1/IU6/IU7. Friend names come
-- from Cypher RETURN — the natural peer pattern (all peers read Person
-- properties directly with zero side tables; §14 was over-corrected for trivial
-- scalar RETURN values).
--
-- Why MessageByCreator rather than Cypher for messages: tested 2026-05-14
-- against local SF3, the Cypher-only 4-arm UNION (HAS_CREATOR.creationDate
-- edge property + composite functional index) ran 135x-388x slower than the
-- prior hybrid. AGE 1.6 cannot push LIMIT past Cypher UNION and cannot bind
-- Cypher edge-property predicates to functional indexes as Index Cond — the
-- date predicate always lands as a post-scan Filter. The side-table shape
-- lets PostgreSQL's planner bind the predicate to the composite index directly
-- and use LATERAL LIMIT 20 for per-friend early termination.
--
-- Index used: idx_msgbycreator_creator_date_msg(creator_business_id, creation_date DESC, message_business_id)
-- — per-friend ordered range scan with both columns as Index Cond.
--
-- Excluded from age_parameterized_queries: $maxDate lives in outer SQL,
-- only Cypher-internal params can be bound through the agtype blob.
SELECT
  m.creator_business_id::ag_catalog.agtype         AS personId,
  ag_catalog.text_to_agtype(friends.first_name)    AS personFirstName,
  ag_catalog.text_to_agtype(friends.last_name)     AS personLastName,
  m.message_business_id::ag_catalog.agtype         AS messageId,
  ag_catalog.text_to_agtype(m.content)             AS messageContent,
  m.creation_date::ag_catalog.agtype               AS messageCreationDate
FROM (
  SELECT (fid::text)::bigint AS person_id,
         fn::text            AS first_name,
         ln::text            AS last_name
  FROM ag_catalog.cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(f:Person)
    WHERE f.id <> $personId
    RETURN f.id AS fid, f.firstName AS fn, f.lastName AS ln
    UNION
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(f:Person)
    WHERE f.id <> $personId
    RETURN f.id AS fid, f.firstName AS fn, f.lastName AS ln
  $$) AS x(fid ag_catalog.agtype, fn ag_catalog.agtype, ln ag_catalog.agtype)
) friends
CROSS JOIN LATERAL (
  SELECT mm.creator_business_id, mm.message_business_id, mm.creation_date, mm.content
  FROM ldbc_snb."MessageByCreator" mm
  WHERE mm.creator_business_id = friends.person_id
    AND mm.creation_date < $maxDate
  ORDER BY mm.creation_date DESC, mm.message_business_id ASC
  LIMIT 20
) m
ORDER BY m.creation_date DESC, m.message_business_id ASC
LIMIT 20;
