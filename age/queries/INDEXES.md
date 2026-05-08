# Index Strategy

This is the most important document for performance review. AGE's query
compilation interacts with PostgreSQL's index machinery in a non-obvious way,
and getting this wrong silently produces sequential scans on every query.

---

## The critical fact: GIN, not B-tree, for property MATCH

When AGE compiles:

```cypher
MATCH (p:Person {id: $personId})
```

it produces a SQL predicate of the form:

```sql
WHERE properties @> '{"id": 933}'::agtype
```

The containment operator `@>` is **only supported by a GIN index** with the
`ag_catalog.gin_agtype_ops` operator class. **A B-tree index on the
extracted value (e.g. `(CAST(agtype_object_field_text(properties,'id') AS bigint))`)
is never used by the planner for this pattern.**
Without the GIN, every `MATCH (n:Label {prop: X})` becomes a
sequential scan over the whole label's vertex table.

---

## Three categories of index

### 1. GIN on `properties` (one per node label)

Backs every `MATCH (n:Label {prop: X})` containment lookup.

```sql
CREATE INDEX gin_person     ON ldbc_snb."Person"     USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_comment    ON ldbc_snb."Comment"    USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_post       ON ldbc_snb."Post"       USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_forum      ON ldbc_snb."Forum"      USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_tag        ON ldbc_snb."Tag"        USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_tagclass   ON ldbc_snb."TagClass"   USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_city       ON ldbc_snb."City"       USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_country    ON ldbc_snb."Country"    USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_continent  ON ldbc_snb."Continent"  USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_company    ON ldbc_snb."Company"    USING GIN (properties ag_catalog.gin_agtype_ops);
CREATE INDEX gin_university ON ldbc_snb."University" USING GIN (properties ag_catalog.gin_agtype_ops);
```

### 2. B-tree on `start_id` / `end_id` (one pair per edge label)

Backs every edge traversal `(a)-[:EDGE]->(b)`. AGE compiles a hop to a join
on the edge table's `start_id` (forward traversal) or `end_id` (reverse).

```sql
CREATE INDEX idx_knows_start        ON ldbc_snb."KNOWS"          (start_id);
CREATE INDEX idx_knows_end          ON ldbc_snb."KNOWS"          (end_id);
-- ... same shape for HAS_CREATOR, REPLY_OF, HAS_TAG, LIKES, CONTAINER_OF,
--     HAS_MEMBER, IS_LOCATED_IN, HAS_INTEREST, WORK_AT, STUDY_AT, HAS_TYPE,
--     IS_SUBCLASS_OF, HAS_MODERATOR, IS_PART_OF
```

15 edge labels × 2 indexes = 30 edge B-trees.

### 3. Functional B-trees on extracted values

These supplement the GIN for two cases:

**(a) Range/equality filters in WHERE clauses, not just MATCH.**  
The GIN handles `MATCH ({creationDate: 12345})` (exact match) but not
`WHERE n.creationDate < $maxDate` (range). For the latter, the planner needs
a functional B-tree on the extracted `bigint` value.

```sql
-- Used by IC2, IC3, IC4, IC7, IC9 (creationDate < maxDate, in date window)
CREATE INDEX idx_comment_date ON ldbc_snb."Comment" (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint));
CREATE INDEX idx_post_date    ON ldbc_snb."Post"    (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint));
```

**(b) Equality on text fields used in WHERE clauses, post-MATCH.**  
Same reason — once a vertex is bound transitively, AGE checks
`WHERE n.name = $X` as a containment per row, which is slow at scale.

```sql
-- Used by IC3, IC4, IC5, IC6, IC11
CREATE INDEX idx_tag_name      ON ldbc_snb."Tag"      (agtype_object_field_text(properties, 'name'));
CREATE INDEX idx_tagclass_name ON ldbc_snb."TagClass" (agtype_object_field_text(properties, 'name'));
CREATE INDEX idx_country_name  ON ldbc_snb."Country"  (agtype_object_field_text(properties, 'name'));

-- Used by IC1 (firstName filter applied post-traversal)
CREATE INDEX idx_person_firstname ON ldbc_snb."Person" (agtype_object_field_text(properties, 'firstName'));
```

**(c) `id` projection / ORDER BY.**  
When a query returns or sorts by `n.id` of a vertex bound transitively,
having a functional B-tree on the extracted id avoids a parallel sort over
the full vertex table.

```sql
CREATE INDEX idx_person_id   ON ldbc_snb."Person"   (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_comment_id  ON ldbc_snb."Comment"  (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_post_id     ON ldbc_snb."Post"     (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_forum_id    ON ldbc_snb."Forum"    (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_tag_id      ON ldbc_snb."Tag"      (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_tagclass_id ON ldbc_snb."TagClass" (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_city_id     ON ldbc_snb."City"     (CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_country_id  ON ldbc_snb."Country"  (CAST(agtype_object_field_text(properties, 'id') AS bigint));
```

**(d) Composite covering for IC2 / IC9.**  
IC2 and IC9 retrieve the most-recent N messages by `creationDate DESC`
and tie-break on `id`. A composite `(creationDate DESC, id)` lets the
planner index-scan in date-desc order without a sort node.

```sql
CREATE INDEX idx_comment_date_id ON ldbc_snb."Comment"
  (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint) DESC,
   CAST(agtype_object_field_text(properties, 'id') AS bigint));
CREATE INDEX idx_post_date_id    ON ldbc_snb."Post"
  (CAST(agtype_object_field_text(properties, 'creationDate') AS bigint) DESC,
   CAST(agtype_object_field_text(properties, 'id') AS bigint));
```

---

## Query → index map

| Query | Primary indexes used |
|---|---|
| IC1 | `gin_person` (entry), `idx_knows_start/end` × 3, `idx_person_firstname` (filter) |
| IC2, IC8, IC9 | `gin_person` (entry), `idx_knows_start/end`, `idx_hascreator_*`, `idx_comment_date_id` / `idx_post_date_id` |
| IC3 | `gin_person`, `idx_knows_*`, `idx_hascreator_*`, `idx_comment_date` / `idx_post_date`, `idx_country_name`, `gin_country` |
| IC4 | `gin_person`, `idx_knows_*`, `idx_hascreator_*`, `idx_hastag_*`, `idx_post_date` |
| IC5 | `gin_person`, `idx_knows_*`, `idx_hasmember_*`, `idx_hascreator_*`, `idx_containerof_*` |
| IC6 | `gin_person`, `idx_knows_*`, `idx_hascreator_*`, `idx_hastag_*`, `idx_tag_name` |
| IC7 | `gin_person`, `idx_hascreator_*`, `idx_likes_*` |
| IC10 | `gin_person`, `idx_knows_*`, `idx_islocatedin_*`, `idx_hascreator_*`, `idx_hastag_*`, `idx_hasinterest_*` |
| IC11 | `gin_person`, `idx_knows_*`, `idx_workat_*`, `idx_islocatedin_*`, `idx_country_name` |
| IC12 | `gin_tagclass` + `idx_tagclass_name` (entry), `gin_person`, `idx_knows_*`, `idx_hascreator_*`, `idx_replyof_*`, `idx_hastag_*`, `idx_hastype_*`, `idx_issubclassof_*` |
| IS1, IS3 | `gin_person`, `idx_islocatedin_*` (IS1), `idx_knows_*` (IS3) |
| IS2 | `gin_person`, `idx_hascreator_*`, `idx_replyof_*`, `idx_comment_date_id` / `idx_post_date_id` |
| IS4, IS5 | `gin_comment` / `gin_post`, `idx_hascreator_*` (IS5) |
| IS6, IS7 | `gin_comment` / `gin_post`, `idx_replyof_*`, `idx_containerof_*` (IS6), `idx_hasmoderator_*` (IS6), `idx_knows_*` (IS7) |
| IU1–IU8 | `gin_*` for entry MATCHes; edge `idx_*_start/end` for existence checks |

---

## What is *not* indexed (and why)

- **`birthMonth` / `birthDay`** — IC10 filters these post-traversal against a
  small candidate set (≤ a few hundred friends-of-friends at SF1000). A
  dedicated B-tree wouldn't reduce work; the GIN handles the rare case where
  someone wants `MATCH (p:Person {birthMonth: 5})`.
- **`Forum.title`, `Comment.content`, `Post.content`** — never used as filter
  predicates in any LDBC IC/IS query; only projected.
- **`STUDY_AT.classYear`, `WORK_AT.workFrom`** — IC11 filters `workFrom` but
  the cardinality after the friend-traversal is small enough that the planner
  doesn't benefit from an edge-property index. (Would revisit at SF1000.)

---

## Build / verify

```bash
psql "$CONNECTION_STRING" -c "SET maintenance_work_mem='2GB';" -f scripts/create-indexes.sql
psql "$CONNECTION_STRING" -c "VACUUM (ANALYZE, VERBOSE) ldbc_snb.\"Person\", ldbc_snb.\"KNOWS\";"
```

`maintenance_work_mem='2GB'` is critical at SF100+ — without it, building the
GIN over 180 M-row edge tables spills to disk and takes hours.
