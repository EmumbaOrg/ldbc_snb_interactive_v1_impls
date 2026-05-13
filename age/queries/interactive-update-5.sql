-- LdbcUpdate5AddForumMembership — adds a person as a forum member.
-- Hybrid: Cypher creates the HAS_MEMBER edge inside the AGE graph and returns
-- the forum and person graphids; outer SQL mirrors the membership into
-- HasMemberSide (a regular table) so IC5 can filter by join_date without
-- touching the AGE-managed HAS_MEMBER table.
--
-- Single-statement INSERT...SELECT FROM cypher() — the Cypher CREATE executes
-- as part of the subquery and the returned graphids feed the INSERT in one
-- transaction. ON CONFLICT handles the rare duplicate-membership case (would
-- otherwise violate PK).

INSERT INTO ldbc_snb."HasMemberSide" (forum_id, member_id, join_date)
SELECT (forum_gid::text)::ag_catalog.graphid,
       (person_gid::text)::ag_catalog.graphid,
       $joinDate
FROM cypher('$graphName', $$
  MATCH (forum:Forum {id: $forumId}), (person:Person {id: $personId})
  CREATE (forum)-[:HAS_MEMBER {joinDate: $joinDate}]->(person)
  RETURN id(forum) AS forum_gid, id(person) AS person_gid
$$) AS (forum_gid agtype, person_gid agtype)
ON CONFLICT (member_id, forum_id) DO UPDATE SET join_date = EXCLUDED.join_date;
