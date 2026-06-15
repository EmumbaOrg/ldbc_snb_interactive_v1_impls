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
| `HAS_MEMBER` | Forum → Person | `joinDate` (bigint) | IC5 reads `joinDate` directly from the Cypher RETURN |
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

## Denormalization & side tables: none (canonical Cypher)

As of **Milestone A (2026-05-30)** there are **no denorm columns and no side
tables**. Every query traverses the canonical graph structure in Cypher; outer
SQL only aggregates/orders/unions/formats the `cypher()` result. `denormalize-
schema.sql` now only issues idempotent `DROP`s + `ANALYZE` (kept so existing
deployments converge).

This is deliberate: the project exists to **surface** AGE's limitations
upstream, not mask them with structures no peer impl (postgres/duckdb/umbra/
cypher/tigergraph) maintains. Denorm is only justified if a peer adopts the same
pattern.

### Why retired structures can't be physically dropped

AGE 1.6 blocks `ALTER TABLE ... DROP COLUMN` on label tables ("table X is for
label X"). Retired denorm columns persist as inert NULL storage on old
deployments until AGE 1.7+ relaxes the guard or the graph is rebuilt. Their
**indexes** were droppable and are gone (migrations under `scripts/migrations/`).

### History (decision-relevant)

- **Side tables retired Milestone A (2026-05-30):** ForumMemberPostCount,
  MessageByCreator, CommentRootPost. Earlier (Phase A/B, 2026-05-28/29):
  HasMemberSide, ForumSide, PersonSide, PersonPostCount. All were §14-compliance
  or aggregate caches; their work moved inline into Cypher.
  - **IC5** computes the per-(forum,member) post count inline via Cypher with
    `WITH DISTINCT friend, forum` staging (prevents 2-hop overcount).
  - **IC9/IC2** use canonical Cypher Comment+Post `HAS_CREATOR` UNION arms.
  - **IC10** computes common/total post counts inline (`OPTIONAL MATCH` +
    `count(DISTINCT …)`, tag overlap via `EXISTS {}` semi-join).
  - **IS2** root-post fields are a Milestone-A placeholder (returns the
    message's own id) pending the VLE fix (Milestone B); see `project_vle_before_after`.
- **Un-retire criterion:** only if AGE gains predicate/LIMIT pushdown through
  Cypher (AGE #1000) — i.e. the inline form stops being structurally slow.
  Slowness here is a *finding to report*, not a thing to hide.
- **Denorm columns retired 2026-05-14/15** (Tier 1–3b): Post.{forum_id,
  country_id, creator_id}, Comment.{creator_id, reply_of_id, country_id},
  Forum.moderator_id, Person.city_id, Tag.tagclass_id, TagClass.subclass_of_id,
  and the City/Country/University/Company place FKs — all replaced by Cypher
  traversal of the underlying edges.
