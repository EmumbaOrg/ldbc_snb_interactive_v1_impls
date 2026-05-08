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
| `HAS_MEMBER` | Forum → Person | `joinDate` (bigint) | |
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
