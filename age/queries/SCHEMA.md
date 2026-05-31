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
| `creator_id` | `HAS_CREATOR`.end_id | IU6 (SQL UPDATE) — read by IC10 |
| ~~`forum_id`~~ | ~~`CONTAINER_OF`.start_id (inverse)~~ | **retired 2026-05-14** — IU6 now sources forum/author gids from Cypher RETURN; no external reader. UPDATE removed from IU6; column + indexes dropped by migration `2026-05-14-drop-post-forum-id.sql`. |
| ~~`country_id`~~ | ~~`IS_LOCATED_IN`.end_id~~ | **retired 2026-05-14** — no read consumer. UPDATE removed from IU6 and `denormalize-schema.sql`; column + index remain (AGE 1.6 ALTER limit). |

### `ldbc_snb."Comment"`

| Column | Source edge | Maintained by |
|---|---|---|
| ~~`creator_id`~~ | ~~`HAS_CREATOR`.end_id~~ | **retired 2026-05-14** — IC12 was migrated to a Cypher-hybrid traversing `(friend)<-[:HAS_CREATOR]-(comment)-[:REPLY_OF]->(post)` directly; no remaining runtime reader. IU7 no longer writes it. Indexes dropped by migration `2026-05-14-retire-comment-creator-replyof.sql`; column stays on disk as NULL (AGE 1.6 ALTER limit). |
| ~~`reply_of_id`~~ | ~~`REPLY_OF`.end_id~~ | **retired 2026-05-14** — IC12 migration removed the last runtime reader. IS2 uses `CommentRootPost`; `denormalize-schema.sql` backfill rewritten to traverse `REPLY_OF` directly. IU7 no longer writes it. Indexes dropped by migration `2026-05-14-retire-comment-creator-replyof.sql`; column stays on disk as NULL (AGE 1.6 ALTER limit). |
| ~~`country_id`~~ | ~~`IS_LOCATED_IN`.end_id~~ | **retired 2026-05-14** — no read consumer. UPDATE removed from IU7 and `denormalize-schema.sql` (was the slowest deploy-time UPDATE at SF3 → ~10 min saved at SF10+). |

### `ldbc_snb."Forum"`

| Column | Source edge | Maintained by |
|---|---|---|
| ~~`moderator_id`~~ | ~~`HAS_MODERATOR`.end_id~~ | **retired 2026-05-14** — no read query referenced it; IU4 no longer writes it. Existing column + index remain (AGE 1.6 blocks `ALTER TABLE` on label tables) but values for new Forums are NULL. Reintroduce as `ForumSide.moderator_id` if a read query ever needs it. |

### `ldbc_snb."Person"`

| Column | Source edge | Maintained by |
|---|---|---|
| ~~`city_id`~~ | ~~`IS_LOCATED_IN`.end_id~~ | **retired 2026-05-14** — no read query referenced it; IU1 no longer writes it. Existing column + index remain (AGE 1.6 ALTER limit). |

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

| Table | Column | Source | Status |
|---|---|---|---|
| `Tag` | `tagclass_id` | `HAS_TYPE`.end_id | active — IC12 now traverses `HAS_TYPE` via Cypher; column may be read by future queries |
| `TagClass` | `subclass_of_id` | `IS_SUBCLASS_OF`.end_id | active — IC12 now traverses `IS_SUBCLASS_OF` via Cypher; column may be read by future queries |
| ~~`City`~~ | ~~`country_id`~~ | ~~`IS_PART_OF`.end_id~~ | **retired 2026-05-14** — no consumer |
| ~~`Country`~~ | ~~`continent_id`~~ | ~~`IS_PART_OF`.end_id~~ | **retired 2026-05-14** — no consumer |
| ~~`University`~~ | ~~`city_id`~~ | ~~`IS_LOCATED_IN`.end_id~~ | **retired 2026-05-14** — no consumer |
| ~~`Company`~~ | ~~`country_id`~~ | ~~`IS_LOCATED_IN`.end_id~~ | **retired 2026-05-14** — no consumer |

Retired columns are no longer backfilled by `denormalize-schema.sql`. The
columns and any indexes on them remain in the AGE schema (AGE 1.6 blocks
`ALTER TABLE DROP COLUMN` on label tables) but values are NULL.

---

## Side tables (iter-2)

Plain PostgreSQL tables (not AGE label tables) that store precomputed
aggregates. AGE 1.7 cannot add `NOT NULL DEFAULT` or array columns to its
managed label tables without triggering a segfault in the Cypher CREATE path,
so these aggregates live in separate tables. See `denormalize-schema.sql`
section 5 for the DDL.

### `ldbc_snb."ForumMemberPostCount"` — RETIRED Milestone A 2026-05-30

Was a precomputed per-(forum, member) post count read by IC5.

IC5 now computes the count inline via Cypher using `WITH DISTINCT friend, forum`
staging before `count(post)` — required to prevent K× overcount from 2-hop
path multiplicity (verified at SF3: staged form matches prior FMPC values).

No peer impl (postgres/duckdb/umbra/cypher/tigergraph) precomputes this counter.
All peers compute the count inline.

**Pre-retirement latency (SF3 baseline):** IC5 p50/p95/p99 ≈ sub-second (indexed lookup).
**Post-retirement expected:** 8–15 s per param at SF3 (AGE 1.6 cannot push HAS_CREATOR
filter into CONTAINER_OF post scan — AGE issue #1000).

**Un-retire when:** AGE gains predicate pushdown / index binding through Cypher
(AGE #1000) so the per-pair count can use an index-backed traversal instead of
a full per-forum scan.

### `ldbc_snb."PersonPostCount"` — RETIRED Phase B 2026-05-29

Was a per-Person total-post-count counter cache read only by IC10. Retired
because IC10 now computes `total_posts` inline as `COUNT(*)` over
`MessageByCreator` (filtered `is_post = true`) in the same LATERAL that computes
`common_posts` — one index range scan per friend, no separate count probe and no
counter to maintain. IU1 no longer seeds it; IU6 no longer increments it;
`denormalize-schema.sql` issues `DROP TABLE IF EXISTS "PersonPostCount"`.

### `ldbc_snb."MessageByCreator"` (2026-05-14, IC9 Phase C)

```sql
(creator_business_id bigint, message_business_id bigint, creation_date bigint,
 content text, is_post boolean)
UNIQUE INDEX (creator_business_id, creation_date DESC, message_business_id)  -- IC9 per-creator walk
UNIQUE INDEX (message_business_id)  -- IS2 lookup by message id, added 2026-05-14
```

- Mirrors `Comment` + `Post` keyed by the **creator's LDBC business id** (bigint).
  `content` stores `Comment.content` or `Post.content`/`Post.imageFile` (whichever
  is non-null, mirroring IC9's projection). `is_post` distinguishes the source.
- Used by IC9 to walk per-friend date-DESC with `LATERAL LIMIT 20`. The composite
  index binds both `creator_business_id` and `creation_date < $maxDate` as
  `Index Cond:`, so each per-friend scan early-terminates at 20 rows.
- Used by IS2 to look up the root post's creator after `CommentRootPost`
  resolves `comment_business_id → root_post_business_id`. The secondary
  unique index on `message_business_id` makes this a single PK probe.
- Maintained by IU6 (AddPost) and IU7 (AddComment): one `INSERT … ON CONFLICT
  DO NOTHING` per new message. No update path — messages are immutable.
- Populated at load time by `denormalize-schema.sql` section 6 (`UNION ALL` over
  `Comment ⨝ Person` and `Post ⨝ Person`).
- Replaces the prior `Comment` + `Post` + `HAS_CREATOR` outer-SQL joins that
  violated AGENTS.md §14. The Cypher-only alternative (`HAS_CREATOR.creationDate`
  edge property + functional index) was tested 2026-05-14 and ran 135x–388x
  slower at SF3 — AGE 1.6 can't push LIMIT past Cypher UNION and edge-property
  predicates don't bind as `Index Cond:` on functional indexes.

### `ldbc_snb."CommentRootPost"` (extended 2026-05-14 for IS2)

```sql
(comment_id ag_catalog.graphid PRIMARY KEY,
 comment_business_id bigint NOT NULL,
 root_post_business_id bigint NOT NULL)
UNIQUE INDEX (comment_business_id)  -- added 2026-05-14 for IS2 lookup-by-bizid
```

- For each Comment, stores the LDBC business id of the root Post reachable
  by walking `REPLY_OF*`. The `comment_id` (graphid) PK lets the iterative
  deploy-time backfill loop join against the `REPLY_OF` edge table directly
  (`Comment.reply_of_id` denorm was retired 2026-05-14).
- Used by IS2 to skip the recursive REPLY_OF walk: a single lookup on
  `comment_business_id` yields the root post id without touching any AGE
  label table. (IS6 was the original target but currently falls back to
  its own SQL walk pending a separate refactor.)
- Maintained by IU7 (AddComment): when the new comment replies to a Post,
  root = `$replyToId`; when it replies to another Comment, root inherits
  the parent comment's `root_post_business_id` via a CommentRootPost lookup.
- Populated at load time by `denormalize-schema.sql` section 6: seed every
  Comment whose direct parent is a Post (by traversing `REPLY_OF` edge table),
  then walk upward iteratively (replaces the prior recursive CTE — see commit `82865047`).

### `ldbc_snb."PersonSide"` (2026-05-14, IC9 Phase C)

```sql
(person_business_id bigint PRIMARY KEY, first_name text, last_name text)
```

- Mirrors `Person.{id, firstName, lastName}` for projection queries that cannot
  read `Person` directly under AGENTS.md §14.
- Used by IC9 for the friend-name projection (`personFirstName`, `personLastName`).
  Could be reused by other queries that need only `id/firstName/lastName`.
- Maintained by IU1 (AddPerson): one `INSERT … ON CONFLICT DO NOTHING`.
- Populated at load time by `denormalize-schema.sql` section 6 from `Person`
  properties. ~10k rows at SF3, scales linearly with Person count.
