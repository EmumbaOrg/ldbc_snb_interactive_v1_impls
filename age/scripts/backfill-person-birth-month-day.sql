-- Backfill birthMonth (int) and birthDay (int) on existing Person nodes.
--
-- Run via:
--   psql "postgresql://postgres:postgres@localhost:5432/postgres" \
--     -f scripts/backfill-person-birth-month-day.sql
--
-- Idempotent: skips rows where both birthMonth and birthDay are already set.
-- Single UPDATE on ldbc_snb."Person" — completes in seconds at SF0.1.
--
-- No B-tree on birthMonth/birthDay needed: IC10 filters them post-MATCH,
-- against a small candidate set (<200 at SF0.1, <2000 at SF1).

LOAD 'age';
SET search_path = ag_catalog, ldbc_snb, public;

BEGIN;

UPDATE ldbc_snb."Person"
SET properties = (
    (properties::text)::jsonb
    || jsonb_build_object(
        'birthMonth',
            EXTRACT(MONTH FROM
              to_timestamp(
                (agtype_object_field_text(properties, 'birthday'))::bigint / 1000.0
              ) AT TIME ZONE 'UTC'
            )::int,
        'birthDay',
            EXTRACT(DAY FROM
              to_timestamp(
                (agtype_object_field_text(properties, 'birthday'))::bigint / 1000.0
              ) AT TIME ZONE 'UTC'
            )::int
    )
)::text::agtype
WHERE agtype_object_field_text(properties, 'birthday') IS NOT NULL
  AND (agtype_object_field_text(properties, 'birthMonth') IS NULL
       OR agtype_object_field_text(properties, 'birthDay') IS NULL);

COMMIT;

VACUUM ANALYZE ldbc_snb."Person";

-- Verify: spot-check a known row.
-- Expected for id=933: birthday=628646400000 -> birthMonth=12, birthDay=3 (1989-12-03 UTC)
SELECT * FROM cypher('ldbc_snb', $$
  MATCH (p:Person {id: 933})
  RETURN p.birthday, p.birthMonth, p.birthDay
$$) AS (bd agtype, bm agtype, bday agtype);
