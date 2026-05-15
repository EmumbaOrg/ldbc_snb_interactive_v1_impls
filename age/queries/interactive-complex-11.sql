-- LdbcQuery11 — Jobs held before workFromYear at companies in a given country, among friends/FoF.
-- Hybrid: two Cypher calls (direct-friend branch, FoF branch) walk KNOWS → WORK_AT → Company →
-- IS_LOCATED_IN → Country and filter by workFrom year. SQL UNION ALL + ORDER + LIMIT.
-- Two-branch UNION ALL: fixed-depth MATCH instead of variable-length path (AGE-QUIRKS §4).
-- FoF branch uses OPTIONAL MATCH direct exclusion pattern (AGE-QUIRKS §10).
-- Directed `-[:KNOWS]->` per AGE-QUIRKS §11.
--
-- Validation fix (2026-05-15): `organizationName::text COLLATE "C" DESC` in ORDER BY.
--   PostgreSQL's default locale-aware collation sorts `.` after uppercase letters; Java's
--   String.compareTo() (used by Neo4j reference) is code-point order (`.`=46 < `A`=65).
--   Same root cause as the IC4 collation bug. COLLATE "C" gives byte-order sort matching
--   the reference. Affects any company name containing `.`, `-`, or non-ASCII characters.
--
-- Performance (2026-05-15): AGE-QUIRKS §12 split applied to WORK_AT → Company and
--   IS_LOCATED_IN → Country traversal in both branches.
--   Approaches considered:
--   A) Current (pre-fix): single 3-hop MATCH `(friend)-[work:WORK_AT]->(company)-[:IS_LOCATED_IN]->(:Country)`.
--      Risk: at SF100+ the AGE planner may build a hash over all Company × IS_LOCATED_IN × Country ×
--      WORK_AT_end rows, then probe with the candidate friend set — a §12 backward hash join spilling
--      to disk (~230 ms extra per branch at SF10 per the IC1 EXPLAIN).
--   B) §12 split (chosen): separate WORK_AT and IS_LOCATED_IN into two 1-hop MATCHes with an
--      intermediate WITH binding company. Forces forward index traversal: idx_workat_start per
--      candidate friend, then idx_islocatedin_start per qualifying company. Mirrors the fix already
--      applied to IC1. Scales linearly with candidate set; no hash build.
--   C) Country-first (reverse traversal): start from Country (GIN on $countryName) → reverse
--      IS_LOCATED_IN → Company → reverse WORK_AT → friend, then MATCH p→KNOWS→friend. Selective
--      entry via Country name is appealing, but reverse WORK_AT can still build a large hash at
--      SF100+ (many jobs per country), and the KNOWS anti-join for FoF exclusion becomes more
--      complex. Rejected.
--
-- Recommendation: Approach B (§12 split) — rule-compliant, matches IC1 pattern, benefits at SF100+.

SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    WITH friend
    MATCH (friend)-[work:WORK_AT]->(company:Company)
    WHERE toInteger(work.workFrom) < $workFromYear
    WITH friend, work, company
    MATCH (company)-[:IS_LOCATED_IN]->(:Country {name: $countryName})
    RETURN friend.id, friend.firstName, friend.lastName, company.name, toInteger(work.workFrom)
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          organizationName agtype, organizationWorkFromYear agtype)
  UNION ALL
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})-[:KNOWS]->(:Person)-[:KNOWS]->(friend:Person)
    WHERE friend.id <> $personId
    OPTIONAL MATCH (p)-[direct:KNOWS]->(friend)
    WITH DISTINCT friend, direct WHERE direct IS NULL
    MATCH (friend)-[work:WORK_AT]->(company:Company)
    WHERE toInteger(work.workFrom) < $workFromYear
    WITH friend, work, company
    MATCH (company)-[:IS_LOCATED_IN]->(:Country {name: $countryName})
    RETURN friend.id, friend.firstName, friend.lastName, company.name, toInteger(work.workFrom)
  $$) AS (personId agtype, personFirstName agtype, personLastName agtype,
          organizationName agtype, organizationWorkFromYear agtype)
) results
ORDER BY organizationWorkFromYear ASC, personId ASC, organizationName::text COLLATE "C" DESC
LIMIT 10;
