# Graph Schema

The `ldbc_snb` graph follows the LDBC SNB Interactive schema. AGE stores each
label as a separate PostgreSQL table; node tables hold an `id` (graphid) and a
`properties` agtype JSON column, edge tables additionally hold `start_id` and
`end_id`.

All `id`, `creationDate`, `joinDate`, `birthMonth`, and `birthDay` properties
are stored as **agtype integers** (not strings). Storing them as strings breaks
`MATCH (n {id: X})` lookups because agtype compares by type before value. See
`AGE-QUIRKS.md`.

---

## Node labels

### `Person`

| Property | Type | Notes |
|---|---|---|
| `id` | bigint | Primary identifier |
| `firstName` | text | |
| `lastName` | text | |
| `gender` | text | |
| `birthday` | bigint | Epoch milliseconds, UTC |
| `birthMonth` | int | 1–12, precomputed from `birthday` (UTC) at load time |
| `birthDay` | int | 1–31, precomputed from `birthday` (UTC) at load time |
| `creationDate` | bigint | Epoch milliseconds |
| `locationIP` | text | |
| `browserUsed` | text | |
| `speaks` | text[] | JSON array of language codes |
| `email` | text[] | JSON array of email addresses |

### `Comment`

| Property | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `creationDate` | bigint | Epoch milliseconds |
| `content` | text | Always populated |
| `length` | int | Character length of `content` |
| `locationIP` | text | |
| `browserUsed` | text | |

### `Post`

| Property | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `creationDate` | bigint | Epoch milliseconds |
| `content` | text \| null | Either `content` or `imageFile` is set, never both. Stored as `null` when missing (not empty string). |
| `imageFile` | text \| null | See above |
| `length` | int | |
| `language` | text | |
| `locationIP` | text | |
| `browserUsed` | text | |

### `Forum`

| Property | Type | Notes |
|---|---|---|
| `id` | bigint | |
| `title` | text | |
| `creationDate` | bigint | Epoch milliseconds |

### `Tag`, `TagClass`

Both have `id` (bigint), `name` (text), `url` (text).

### `City`, `Country`, `Continent`

All have `id` (bigint), `name` (text), `url` (text).

### `Company`, `University`

Both have `id` (bigint), `name` (text), `url` (text), plus `placeId` (bigint)
and `placeName` (text) populated at load time from the
`organisation_isLocatedIn_place` CSV (denormalised to avoid an extra join in
some IC1 paths).

---

## Edge labels

KNOWS is **stored bidirectionally** — every friendship has two rows, A→B and
B→A — so all read queries can use `(p)-[:KNOWS]->(friend)` without worrying
about direction. IU8 (add friendship) creates both rows in one transaction.

| Edge | Direction | Properties | Notes |
|---|---|---|---|
| `KNOWS` | Person → Person | `creationDate` (bigint) | **Bidirectional** — both directions stored |
| `HAS_CREATOR` | Comment\|Post → Person | — | Two source CSVs unified into one edge label |
| `REPLY_OF` | Comment → Comment\|Post | — | Target can be either label; queries handle this with chained OPTIONAL MATCH |
| `CONTAINER_OF` | Forum → Post | — | A Post belongs to exactly one Forum |
| `HAS_MEMBER` | Forum → Person | `joinDate` (bigint) | Mirrored into the `HasMemberSide` side table for IC5 (see "Side tables" below) — the AGE table itself is not read by outer SQL |
| `HAS_MODERATOR` | Forum → Person | — | |
| `LIKES` | Person → Comment\|Post | `creationDate` (bigint) | |
| `HAS_INTEREST` | Person → Tag | — | |
| `STUDY_AT` | Person → University | `classYear` (text) | Stored as text in source CSV, cast to int in queries |
| `WORK_AT` | Person → Company | `workFrom` (text) | Same — cast to int in IC11 |
| `IS_LOCATED_IN` | Comment\|Post → Country, Person → City, Company → Country, University → City | — | One label, four `(start, end)` combinations |
| `IS_PART_OF` | City → Country, Country → Continent | — | Two combinations under one label |
| `HAS_TYPE` | Tag → TagClass | — | |
| `IS_SUBCLASS_OF` | TagClass → TagClass | — | Hierarchy ≤ 6 levels in LDBC reference data |
| `HAS_TAG` | Comment\|Post\|Forum → Tag | — | |

---

## Storage notes

- **agtype** is AGE's JSON-like value type. Numeric properties are emitted by
  the loader as bare integer literals (`{"id": 933}`) so containment matches.
- **Multi-label edges** (`HAS_CREATOR`, `REPLY_OF`, `IS_LOCATED_IN`,
  `IS_PART_OF`, `LIKES`, `HAS_TAG`) live in a single PostgreSQL table per
  label. Both endpoints' actual labels are recoverable via the start_id /
  end_id graph IDs.
- **AGE has no datetime type.** All temporal values are epoch-milliseconds
  bigints. Date arithmetic (`maxDate < creationDate`, etc.) is integer
  comparison. IC10's birthday-window logic uses the precomputed
  `birthMonth`/`birthDay` integer fields to avoid date math in the query path.

---

## Denormalization columns (iter-1/2/3)

Added by `age/scripts/denormalize-schema.sql`. These columns store graphids
copied from the corresponding edge tables, enabling direct B-tree joins in
hybrid SQL/Cypher queries without an extra edge-table lookup.

Columns are populated at load time by `denormalize-schema.sql` and maintained
on subsequent writes by the IU operations listed. All columns are of type
`ag_catalog.graphid` (nullable — NULL until backfilled or inserted).

### `ldbc_snb."Post"`

| Column | Source edge | Maintained by |
|---|---|---|
| `creator_id` | `HAS_CREATOR`.end_id | IU6 (SQL UPDATE) |
| `forum_id` | `CONTAINER_OF`.start_id (inverse) | IU6 (SQL UPDATE) |
| `country_id` | `IS_LOCATED_IN`.end_id | IU6 (SQL UPDATE) |

### `ldbc_snb."Comment"`

| Column | Source edge | Maintained by |
|---|---|---|
| `creator_id` | `HAS_CREATOR`.end_id | IU7 (SQL UPDATE) |
| `reply_of_id` | `REPLY_OF`.end_id | IU7 (SQL UPDATE) |
| `country_id` | `IS_LOCATED_IN`.end_id | IU7 (SQL UPDATE) |

### `ldbc_snb."Forum"`

| Column | Source edge | Maintained by |
|---|---|---|
| `moderator_id` | `HAS_MODERATOR`.end_id | IU4 (SQL UPDATE) |

### `ldbc_snb."Person"`

| Column | Source edge | Maintained by |
|---|---|---|
| `city_id` | `IS_LOCATED_IN`.end_id | IU1 (SQL UPDATE) |

### Side tables (mirrors — outer SQL never reads AGE tables)

Per client directive 2026-05-13: outer SQL must not directly access AGE-managed
tables. The denorm columns above on `Post`/`Comment`/`Forum`/`Person` are legacy
and tracked for migration to side tables. Phase 3B's `HAS_MEMBER.join_date`
column was replaced by the side-table pattern below.

#### `ldbc_snb."HasMemberSide"`

| Column | Source | Maintained by |
|---|---|---|
| `forum_id` | `HAS_MEMBER.start_id` | IU5 (INSERT from cypher() result) |
| `member_id` | `HAS_MEMBER.end_id` | IU5 |
| `join_date` | `HAS_MEMBER.properties->'joinDate'` (cast to bigint) | IU5 |

PK `(member_id, forum_id)`; secondary index `(member_id, join_date)`. Backfilled
from `HAS_MEMBER` at deploy time. Used by IC5 as the directive-compliant
replacement for the prior `HAS_MEMBER.join_date` column. The HAS_MEMBER column
of the same name still exists in the AGE table (AGE 1.6 blocks DROP COLUMN on
label tables) but is unindexed and unreferenced.

#### `ldbc_snb."ForumSide"`

| Column | Source | Maintained by |
|---|---|---|
| `forum_id` | `Forum.id` (graphid) | IU4 (INSERT from cypher() result) |
| `forum_business_id` | `Forum.properties->'id'` (LDBC public id, bigint) | IU4 |
| `title` | `Forum.properties->'title'` (text) | IU4 |

PK on `forum_id`. Used by IC5 to read forum titles and the IC5 ORDER BY
tie-breaker (`forum_business_id`) without invoking `agtype_access_operator` on
each top-20 row.

### Additional denorm columns (also in `denormalize-schema.sql`)

The following columns are also added by the schema script but are not yet
used by the current IC/IS/IU queries. They are present for potential future
query optimizations:

| Table | Column | Source |
|---|---|---|
| `Tag` | `tagclass_id` | `HAS_TYPE`.end_id |
| `TagClass` | `subclass_of_id` | `IS_SUBCLASS_OF`.end_id — used by IC12 |
| `City` | `country_id` | `IS_PART_OF`.end_id |
| `Country` | `continent_id` | `IS_PART_OF`.end_id |
| `University` | `city_id` | `IS_LOCATED_IN`.end_id |
| `Company` | `country_id` | `IS_LOCATED_IN`.end_id |

Note: `Tag.tagclass_id` and `TagClass.subclass_of_id` are actively used by IC12.

---

## Side tables (iter-2)

Plain PostgreSQL tables (not AGE label tables) that store precomputed
aggregates. AGE 1.7 cannot add `NOT NULL DEFAULT` or array columns to its
managed label tables without triggering a segfault in the Cypher CREATE path,
so these aggregates live in separate tables. See `denormalize-schema.sql`
section 5 for the DDL.

### `ldbc_snb."ForumMemberPostCount"`

```sql
(forum_id ag_catalog.graphid, member_id ag_catalog.graphid, post_count int, PRIMARY KEY (forum_id, member_id))
```

- Stores the count of Posts each Person (member) made in each Forum.
- Used by IC5 V11: replaces a per-pair `Post` LEFT JOIN with a single index lookup.
- Maintained by IU6 (AddPost): `INSERT … ON CONFLICT … DO UPDATE SET post_count = post_count + 1`.
- Populated at load time by `denormalize-schema.sql` section 6 (aggregate from `Post.creator_id` + `Post.forum_id`).
- Secondary index: `idx_fmpc_member` on `member_id`.

### `ldbc_snb."PersonPostCount"`

```sql
(person_id ag_catalog.graphid PRIMARY KEY, post_count int NOT NULL DEFAULT 0)
```

- Stores total post count per Person.
- Used by IC10 V5: provides `total_posts` in a single primary-key lookup,
  avoiding a count over all Posts by the FoF candidate.
- Maintained by IU6 (AddPost): `UPDATE … SET post_count = post_count + 1`.
- Populated at load time from `Post.creator_id`; every Person has a row
  (even those with 0 posts) so IU6 can always use `UPDATE` (no INSERT race).
