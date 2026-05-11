-- LdbcQuery7 — Most recent likers of the user's messages, with latency and knows-flag.
-- Hybrid: two Cypher calls (Comment branch, Post branch) use collect+UNWIND to force
-- AGE's planner to bind the (small) message set first, then probe LIKES via idx_likes_end
-- NL rather than a full LIKES seq-scan. DISTINCT ON (latest like per liker) stays in SQL.
-- Two-branch UNION ALL because AGE has no multi-label MATCH (AGE-QUIRKS §3).
-- Tie-breaking: DISTINCT ON ordered by likeCreationDate DESC, commentOrPostId ASC (spec §9 in AGENTS.md).

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
      WITH p, liker, msg, like.creationDate AS likeTime
      OPTIONAL MATCH (p)-[knows:KNOWS]->(liker)
      RETURN liker.id, liker.firstName, liker.lastName, likeTime, msg.id,
             coalesce(msg.content, msg.imageFile),
             toInteger(floor(toFloat(likeTime - msg.creationDate) / 60000.0)),
             knows IS NULL
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, commentOrPostId agtype, commentOrPostContent agtype,
            minutesLatency agtype, isNew agtype)
    UNION ALL
    SELECT * FROM cypher('$graphName', $$
      MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post)
      WITH p, collect(msg) AS msgs
      UNWIND msgs AS msg
      MATCH (msg)<-[like:LIKES]-(liker:Person)
      WITH p, liker, msg, like.creationDate AS likeTime
      OPTIONAL MATCH (p)-[knows:KNOWS]->(liker)
      RETURN liker.id, liker.firstName, liker.lastName, likeTime, msg.id,
             coalesce(msg.content, msg.imageFile),
             toInteger(floor(toFloat(likeTime - msg.creationDate) / 60000.0)),
             knows IS NULL
    $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
            likeCreationDate agtype, commentOrPostId agtype, commentOrPostContent agtype,
            minutesLatency agtype, isNew agtype)
  ) all_likes
  ORDER BY personId, likeCreationDate DESC, commentOrPostId ASC
) latest_likes
ORDER BY likeCreationDate DESC, personId ASC
LIMIT 20;
