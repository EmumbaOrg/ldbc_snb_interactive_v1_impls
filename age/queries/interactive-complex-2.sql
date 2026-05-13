-- LdbcQuery2 — Top-20 recent messages by direct friends (before maxDate).
-- Directive-compliant (2026-05-13): all graph traversal is inside the Cypher call;
-- outer SQL only casts agtype columns and applies ORDER BY + LIMIT.
-- Two-arm UNION ALL inside Cypher because AGE has no polymorphic Message label
-- (AGE-QUIRKS §3). Post arm uses COALESCE(content, imageFile) per the LDBC spec;
-- Comment arm uses content (imageFile is always null for Comments).
-- Sort: messageCreationDate DESC, messageId ASC (LDBC IC2 spec §2.4).
-- Indexes used: gin_person (seed), idx_knows_start (directed friend hop),
--   idx_hascreator_end (HAS_CREATOR reverse), idx_post_creationdate_agtype,
--   idx_comment_creationdate_agtype (date filter inside Cypher call).

-- Keep `content` as agtype, NOT cast to ::text. AgeConverter.toStr unwraps the
-- outer JSON quotes of an agtype string before any trim, preserving content's
-- internal trailing whitespace (LDBC datagen produces messages with significant
-- trailing chars). A ::text cast bypasses the unwrap and triggers .trim() on
-- the bare value, stripping the trailing space and breaking validation.
SELECT (fid::text)::bigint       AS personId,
       fn::text                   AS personFirstName,
       ln::text                   AS personLastName,
       (mid::text)::bigint        AS messageId,
       content                    AS messageContent,
       (cd::text)::bigint         AS messageCreationDate
FROM cypher('$graphName', $$
  MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
  MATCH (friend)<-[:HAS_CREATOR]-(post:Post)
  WHERE post.creationDate <= $maxDate
  RETURN friend.id AS fid, friend.firstName AS fn, friend.lastName AS ln,
         post.id AS mid,
         CASE WHEN post.content IS NOT NULL THEN post.content ELSE post.imageFile END AS content,
         post.creationDate AS cd
  UNION ALL
  MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
  MATCH (friend)<-[:HAS_CREATOR]-(c:Comment)
  WHERE c.creationDate <= $maxDate
  RETURN friend.id AS fid, friend.firstName AS fn, friend.lastName AS ln,
         c.id AS mid, c.content AS content, c.creationDate AS cd
$$) AS x(fid agtype, fn agtype, ln agtype, mid agtype, content agtype, cd agtype)
ORDER BY (cd::text)::bigint DESC, (mid::text)::bigint ASC
LIMIT 20;
