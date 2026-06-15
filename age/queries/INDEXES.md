# Index Strategy

The most important performance doc. AGE compiles a Cypher anchor to one of two
SQL predicate shapes, and the shape decides which index can bind. Get it wrong
and the query silently seq-scans the whole label table.

This file mirrors `scripts/create-indexes.sql` (the source of truth).

---

## Two anchor shapes — choose the index by how the anchor is written

| Shape | Cypher anchor | Compiled predicate | Index that binds |
|---|---|---|---|
| **#1 map-form** | `MATCH (n:Label {id: X})` | `properties @> '{"id": X}'::agtype` | **GIN** (`gin_agtype_ops`). A functional B-tree does not support `@>` and is never picked for this form. |
| **#2 WHERE-form** | `MATCH (n:Label) WHERE n.id = X` | `agtype_access_operator(VARIADIC ARRAY[properties,'"id"'::agtype]) = X` | **functional B-tree** on that exact expression (PG expression-index matching is byte-exact). |

Both bind only for **literal/parameter values known at plan time**. Runtime
values from `UNWIND`/`WITH`/function output fall to seq scans regardless of shape
(AGE-QUIRKS §15). The runtime path string-substitutes every parameter as a
literal (CLAUDE.md §13), so both shapes bind reliably in production.

> **Correction (2026-06-01):** the older claim that functional B-trees "never
> bind from Cypher" (AGE #1000) is true only for shape #1. Shape #2 **does**
> bind — verified Index Scan at SF3, including when the anchor starts a
> traversal. This is what enabled the Post/Comment GIN→B-tree migration below.

### Why Post/Comment use shape #2 (not GIN)

Post and Comment are only ever anchored by `id` (IS4/5/6/7, IU2/3/7 — all written
`WHERE m.id = $x`). A GIN over their `properties` tokenizes **every** key,
including the free-text `content`/`imageFile`, producing a multi-GB index that
ran the **SF100 load out of disk** (SF3: `gin_comment` 1199 MB, `gin_post`
623 MB). The functional id B-tree indexes only the id scalar — ~5× smaller and
faster (exact single-row, no bitmap recheck). `gin_post`/`gin_comment` are
retired and removed from the loader's GIN loop.

---

## Index inventory

### 1. GIN on `properties` — 6 labels (shape #1 anchors)

`Person, Forum, Tag, City, Company, University` — anchored by `{id:}`/`{name:}`.

```sql
CREATE INDEX gin_person ON ldbc_snb."Person" USING GIN (properties ag_catalog.gin_agtype_ops);
-- + gin_forum, gin_tag, gin_city, gin_company, gin_university
```

Excluded on purpose: **Post/Comment** (shape #2 id B-tree, see above);
**Country/Continent/TagClass** (fixed-size reference tables the planner always
seq-scans — their GINs measured `idx_scan = 0`).

### 2. Edge `start_id` / `end_id` B-trees — 15 edges × 2

Backs every `(a)-[:EDGE]->(b)` hop (forward = `start_id`, reverse = `end_id`)
for all 15 edge labels: KNOWS, HAS_CREATOR, REPLY_OF, CONTAINER_OF, HAS_MEMBER,
HAS_MODERATOR, LIKES, HAS_INTEREST, STUDY_AT, WORK_AT, IS_LOCATED_IN, IS_PART_OF,
HAS_TYPE, IS_SUBCLASS_OF, HAS_TAG.

### 3. Per-label graphid `id` B-trees — 11 labels

AGE child label tables don't inherit the parent PK on `id` (graphid), so any
`JOIN <Label> ON id = <graphid>` seq-scans without these.

```sql
CREATE INDEX idx_person_graphid ON ldbc_snb."Person" (id);  -- + 10 other vertex labels
```

### 4. agtype-access functional B-trees on Post/Comment — date + id (shape #2)

Match AGE's compiled `agtype_access_operator(...)` predicate byte-exact:

```sql
-- date-range filters: msg.creationDate < $maxDate  (IC2/IC3/IC4/IC9)
idx_comment_creationdate_agtype, idx_post_creationdate_agtype
-- id anchors (REPLACE gin_comment/gin_post): WHERE m.id = $x  (IS4/5/6/7, IU2/3/7)
idx_comment_id_agtype, idx_post_id_agtype
```

---

## Query → index family

| Query group | Indexes used |
|---|---|
| Person-anchored IC/IS (IC1–IC12, IS1/IS3) | `gin_person` seed + edge `idx_*_start/end` per hop |
| Post/Comment-anchored IS (IS4/5/6/7) | `idx_{post,comment}_id_agtype` seed + edge indexes |
| Date-window filters (IC2/IC3/IC4/IC9) | `idx_{post,comment}_creationdate_agtype` |
| KNOWS traversal (always directed `->`) | `idx_knows_start` (AGE-QUIRKS §11) |
| Name lookups (Tag in IC6; Country in IC3/IC11) | `gin_tag`; Country seq-scans (small ref table, no GIN) |
| IU1–IU8 | `gin_*` / `idx_{post,comment}_id_agtype` entry anchors; edge indexes for existence checks |

No side tables, denorm columns, or composite covering indexes remain — see
History.

---

## What is NOT indexed (and why)

- **`content`/`imageFile`, `Forum.title`** — only projected, never filtered; a
  GIN over them was the SF100 disk blocker.
- **`birthMonth`/`birthDay`** — IC10 filters post-traversal on a small FoF set.
- **`STUDY_AT.classYear`, `WORK_AT.workFrom`** — post-traversal cardinality is
  small; revisit at SF1000.
- **`CAST(agtype_object_field_text(...) AS bigint)` functional B-trees** — never
  matched AGE's compiled `agtype_access_operator(...)` predicate (`idx_scan = 0`);
  removed. Use the agtype-access form (§4) for any new date/id index.

---

## History (decision-relevant)

- **2026-06-01** — Functional B-tree binds via shape #2; corrects the AGE #1000
  "never binds" assumption and unblocked the Post/Comment GIN→B-tree migration.
- **SF100 disk** — `gin_post`/`gin_comment` retired (content tokenization →
  multi-GB index that exhausted disk during load).
- **Milestone A (2026-05-30)** — all side tables and their indexes dropped
  (ForumMemberPostCount, MessageByCreator, CommentRootPost, HasMemberSide,
  ForumSide, PersonSide, PersonPostCount); queries went canonical Cypher.
- **2026-05-14/15** — all denorm-column B-trees and the IC2 `(creator, date)`
  composites dropped (unused after the IC2/IC12 rewrites).
- **CAST-form date/id/name functional B-trees** — removed (wrong predicate shape,
  never scanned).

---

## Build / verify

```bash
psql "$CONNECTION_STRING" -c "SET maintenance_work_mem='2GB';" -f scripts/create-indexes.sql
```

`maintenance_work_mem='2GB'` matters at SF100+ so GIN builds don't spill to disk.
`load-data.sh` runs this automatically (Step 3); the manual command is for the
dev load path.
