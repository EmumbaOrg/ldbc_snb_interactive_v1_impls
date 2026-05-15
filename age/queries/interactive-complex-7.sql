-- LdbcQuery7 — Most recent likers of the user's messages, with latency and knows-flag.
-- Hybrid: two Cypher calls (Comment branch, Post branch) use collect+UNWIND to force
-- AGE's planner to bind the (small) message set first, then probe LIKES via idx_likes_end
-- NL rather than a full LIKES seq-scan. DISTINCT ON (latest like per liker) stays in SQL.
-- Two-branch UNION ALL because AGE has no multi-label MATCH (AGE-QUIRKS §3).
-- Tie-breaking: DISTINCT ON ordered by likeCreationDate DESC, commentOrPostId ASC (AGENTS.md §9).
--
-- isNew flag: `NOT EXISTS { MATCH (p)-[:KNOWS]->(liker) }` instead of an OPTIONAL MATCH +
-- `knows IS NULL` projection. The OPTIONAL MATCH variant forces the planner to carry
-- `p` and `knows` through the entire RETURN row stream and to compute the (p)-[:KNOWS]
-- traversal once per liker even though we only need a boolean. Measured 2026-05-15 SF3:
-- replacing OPTIONAL MATCH with NOT EXISTS gave a 50-200× speedup (mean ~124× across 5
-- sample personIds) with byte-identical output. AGE 1.6 EXISTS subqueries plan as
-- short-circuit semi-joins (AGENTS.md §"AGE 1.6 Cypher Constructs — EXISTS").

SELECT personId, personFirstName, personLastName, likeCreationDate, commentOrPostId,
       commentOrPostContent, minutesLatency, isNew
FROM (
  SELECT DISTINCT ON (personId)
    personId, personFirstName, personLastName, likeCreationDate, commentOrPostId,
    commentOrPostContent, minutesLatency, isNew
  FROM (
    SELECT * FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)
      WITH p, collect(msg) AS msgs
      UNWIND msgs AS msg
      MATCH (msg)<-[like:LIKES]-(liker:Person)
      RETURN liker.id, liker.firstName, liker.lastName, like.creationDate, msg.id,
             coalesce(msg.content, msg.imageFile),
             toInteger(floor(toFloat(like.creationDate - msg.creationDate) / 60000.0)),
             NOT EXISTS { MATCH (p)-[:KNOWS]->(liker) }
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, commentOrPostId agtype, commentOrPostContent agtype,
            minutesLatency agtype, isNew agtype)
    UNION ALL
    SELECT * FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)
      WITH p, collect(msg) AS msgs
      UNWIND msgs AS msg
      MATCH (msg)<-[like:LIKES]-(liker:Person)
      RETURN liker.id, liker.firstName, liker.lastName, like.creationDate, msg.id,
             coalesce(msg.content, msg.imageFile),
             toInteger(floor(toFloat(like.creationDate - msg.creationDate) / 60000.0)),
             NOT EXISTS { MATCH (p)-[:KNOWS]->(liker) }
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, commentOrPostId agtype, commentOrPostContent agtype,
            minutesLatency agtype, isNew agtype)
  ) all_likes
  ORDER BY personId, likeCreationDate DESC, commentOrPostId ASC
) latest_likes
ORDER BY likeCreationDate DESC, personId ASC
LIMIT 20;
