-- LdbcQuery9 — Recent messages by friends and friends-of-friends
--
-- Why this is raw SQL instead of cypher():
--   The original Cypher (kept as a commented banner below) was four cypher()
--   calls UNION-ALL'd:
--     1. direct friends + Comment messages
--     2. direct friends + Post    messages
--     3. friends-of-friends (FoF) + Comment messages   ← dominated cost
--     4. friends-of-friends (FoF) + Post    messages   ← dominated cost
--   The outer SQL did `ORDER BY messageCreationDate DESC, messageId ASC LIMIT 20`.
--
--   Measured at SF0.1 (sample input: 10 direct friends, 451 FoFs):
--     Total    685 ms execution, 896 580 buffers hit, 22.7 ms planning.
--     Branch 3 alone: 72 968 candidate Comment rows, 636 ms, 449 291 buffers.
--     Branch 4 alone: 40 035 candidate Post    rows, 447 ms, 415 777 buffers.
--   Each FoF branch re-walked the 2-hop KNOWS pattern, deduped, ran the
--   `OPTIONAL MATCH (p)-[direct]->(friend) WITH DISTINCT WHERE direct IS NULL`
--   anti-join idiom (sorts on materialised vertex agtypes), then materialised
--   *every* message by *every* FoF in the date window before the outer LIMIT.
--   The composite idx_comment_date_id / idx_post_date_id (creationDate DESC, id)
--   were never used because the join order was friend → HAS_CREATOR → msg.
--
--   The pure-SQL rewrite below — same approach as SQ6 and IS4 — produced
--   byte-identical results in 12-20 ms (50× faster) on two LDBC substitution
--   inputs. Strategy:
--     1. Compute the 1-hop and 2-hop friend sets ONCE in CTEs (vs twice in
--        the Cypher).
--     2. Walk idx_comment_date_id / idx_post_date_id from `creationDate
--        < $maxDate` backwards, applying a Nested Loop Semi Join against
--        all_friends so the index walk stops as soon as 20 friend-authored
--        rows are accumulated (39 Comment + 2 Post rows touched on the
--        sample input).
--     3. Merge Append the per-label top-20s, take outer top-20.
--   Output columns are wrapped via ag_catalog.agtype_access_operator and
--   ::ag_catalog.agtype casts so AgeConverter.toLong / AgeConverter.toStr
--   in AgeDb.InteractiveQuery9.toResult continue to work unchanged.
--
-- Original Cypher implementation, kept for reference:
-- ----------------------------------------------------------------------------
-- SELECT * FROM (
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)<-[:HAS_CREATOR]-(msg:Comment)
--     WHERE msg.creationDate < $maxDate AND friend.id <> $personId
--     RETURN friend.id, friend.firstName, friend.lastName, msg.id,
--            coalesce(msg.content, msg.imageFile), msg.creationDate
--   $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
--           messageId agtype, messageContent agtype, messageCreationDate agtype)
--   UNION ALL
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)<-[:HAS_CREATOR]-(msg:Post)
--     WHERE msg.creationDate < $maxDate AND friend.id <> $personId
--     RETURN friend.id, friend.firstName, friend.lastName, msg.id,
--            coalesce(msg.content, msg.imageFile), msg.creationDate
--   $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
--           messageId agtype, messageContent agtype, messageCreationDate agtype)
--   UNION ALL
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
--     WHERE friend.id <> $personId
--     OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
--     WITH DISTINCT friend, direct WHERE direct IS NULL
--     MATCH (friend)<-[:HAS_CREATOR]-(msg:Comment)
--     WHERE msg.creationDate < $maxDate
--     RETURN friend.id, friend.firstName, friend.lastName, msg.id,
--            coalesce(msg.content, msg.imageFile), msg.creationDate
--   $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
--           messageId agtype, messageContent agtype, messageCreationDate agtype)
--   UNION ALL
--   SELECT * FROM cypher('$graphName', $$
--     MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
--     WHERE friend.id <> $personId
--     OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
--     WITH DISTINCT friend, direct WHERE direct IS NULL
--     MATCH (friend)<-[:HAS_CREATOR]-(msg:Post)
--     WHERE msg.creationDate < $maxDate
--     RETURN friend.id, friend.firstName, friend.lastName, msg.id,
--            coalesce(msg.content, msg.imageFile), msg.creationDate
--   $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
--           messageId agtype, messageContent agtype, messageCreationDate agtype)
-- ) recent_messages
-- ORDER BY messageCreationDate DESC, messageId ASC
-- LIMIT 20;
-- ----------------------------------------------------------------------------

WITH person AS (
  SELECT id
  FROM ldbc_snb."Person"
  WHERE CAST(ag_catalog.agtype_object_field_text(properties, 'id') AS bigint) = $personId
),
direct_knows AS (
  SELECT k.end_id AS friend_id
  FROM ldbc_snb."KNOWS" k
  JOIN person p ON k.start_id = p.id
),
foaf AS (
  -- 2-hop minus 1-hop minus self.
  SELECT DISTINCT k2.end_id AS friend_id
  FROM direct_knows d
  JOIN ldbc_snb."KNOWS" k2 ON k2.start_id = d.friend_id
  WHERE k2.end_id NOT IN (SELECT friend_id FROM direct_knows)
    AND k2.end_id <> (SELECT id FROM person)
),
all_friends AS (
  SELECT friend_id FROM direct_knows
  UNION
  SELECT friend_id FROM foaf
),
top_comments AS (
  -- Walk idx_comment_date_id from `< $maxDate` backwards; the planner stops
  -- the index walk as soon as the Nested Loop Semi Join accumulates 20 rows
  -- whose creator is in all_friends.
  SELECT msg.id      AS msg_gid,
         msg.properties AS msg_props,
         hc.end_id   AS author_gid,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) AS cdate,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint)           AS msg_id_biz
  FROM ldbc_snb."Comment" msg
  JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = msg.id
  WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) < $maxDate
    AND hc.end_id IN (SELECT friend_id FROM all_friends)
  ORDER BY 4 DESC, 5 ASC
  LIMIT 20
),
top_posts AS (
  SELECT msg.id      AS msg_gid,
         msg.properties AS msg_props,
         hc.end_id   AS author_gid,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) AS cdate,
         CAST(ag_catalog.agtype_object_field_text(msg.properties, 'id') AS bigint)           AS msg_id_biz
  FROM ldbc_snb."Post" msg
  JOIN ldbc_snb."HAS_CREATOR" hc ON hc.start_id = msg.id
  WHERE CAST(ag_catalog.agtype_object_field_text(msg.properties, 'creationDate') AS bigint) < $maxDate
    AND hc.end_id IN (SELECT friend_id FROM all_friends)
  ORDER BY 4 DESC, 5 ASC
  LIMIT 20
),
top_all AS (
  SELECT * FROM top_comments
  UNION ALL
  SELECT * FROM top_posts
)
SELECT
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"id"'::ag_catalog.agtype])         AS personId,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"firstName"'::ag_catalog.agtype])  AS personFirstName,
  ag_catalog.agtype_access_operator(VARIADIC ARRAY[per.properties, '"lastName"'::ag_catalog.agtype])   AS personLastName,
  t.msg_id_biz::ag_catalog.agtype                                                                      AS messageId,
  COALESCE(
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.msg_props, '"content"'::ag_catalog.agtype]),
    ag_catalog.agtype_access_operator(VARIADIC ARRAY[t.msg_props, '"imageFile"'::ag_catalog.agtype])
  )                                                                                                    AS messageContent,
  t.cdate::ag_catalog.agtype                                                                           AS messageCreationDate
FROM top_all t
JOIN ldbc_snb."Person" per ON per.id = t.author_gid
ORDER BY t.cdate DESC, t.msg_id_biz ASC
LIMIT 20;

-- ----------------------------------------------------------------------------
-- Future optimization steps (pick up when needed):
--
-- 1. Schema denormalization for SF1000 — at higher SFs, friend density of the
--    date window can drop, lengthening the date-DESC index walk before 20
--    friend-authored rows are found. The fix is to push creationDate into the
--    HAS_CREATOR edge itself (populated by IU6/IU7 and backfilled at load),
--    then add a composite index:
--      ALTER TABLE ldbc_snb."HAS_CREATOR" ADD COLUMN creation_date bigint;
--      CREATE INDEX idx_hascreator_end_creationdate
--        ON ldbc_snb."HAS_CREATOR" (end_id, creation_date DESC);
--    With that, IC9 becomes a k-way merge of per-friend top-20 streams —
--    O(log N + 20) per friend, robust regardless of friend density. Touches
--    IU operations, schema, and load — out of scope for the query rewrite.
--
-- 2. Apply the same V3 pattern to IC2 — sibling query (recent messages by
--    direct friends only, no FoF). Same 2-branch UNION ALL shape; replacing
--    with a date-driven semi-join CTE should drop IC2 from ~115 ms mean to
--    single-digit ms. Quick follow-up if it shows up in profiling again.
--
-- 3. Investigate AGE's per-call cypher() overhead — the SQ6, IS4, and IC9
--    rewrites have all sidestepped a fixed ~150 ms tax that appears whenever
--    cypher() returns string content. Worth a profiling session to identify
--    where in AGE's parse → execute → serialize path that overhead lives,
--    so it can be fixed for queries that genuinely need Cypher.
-- ----------------------------------------------------------------------------
