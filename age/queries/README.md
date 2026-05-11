# AGE queries

SQL/Cypher queries for Apache AGE. Each `.sql` file begins with `SET search_path = ag_catalog, public;`
followed by one or more `SELECT * FROM cypher(...)` calls.

Use the `./check-feature.sh` script to check for Cypher features used across query files. Some examples:

```bash
# variable-length paths
./check-feature.sh ':\w*\*'
# count
./check-feature.sh 'count('
# OPTIONAL MATCH
./check-feature.sh 'OPTIONAL MATCH'
# UNWIND
./check-feature.sh 'UNWIND'
# UNION ALL
./check-feature.sh 'UNION ALL'
```

## Notes

- **IC13 / IC14**: Apache AGE does not support `shortestPath()` or `allShortestPaths()`. These are degraded stubs — IC13 always returns `-1`, IC14 always returns an empty list. Their `.sql` files are placeholders only.
- All dates are stored and compared as epoch milliseconds (bigint).
- Pattern predicates in `WHERE` or `CASE WHEN` are not supported by AGE; these are rewritten using `OPTIONAL MATCH` + null checks.

### IS2 implementation note

IS2 was previously implemented with an 8-level chained `OPTIONAL MATCH` ladder in Cypher to walk the REPLY_OF chain. This caused Parallel Append seq-scans over all vertex labels at each level (the "unlabeled intermediate" pathology documented in AGE-QUIRKS §9) and produced ~2.8 s latency at SF0.1. The current implementation (V2) eliminates this pathology:

- Two Cypher calls (`Comment` branch, `Post` branch) fetch the top-10 messages via `HAS_CREATOR`, each with `ORDER BY … LIMIT 10` as a final `RETURN` — safe because there is no mid-query `LIMIT` feeding further Cypher clauses.
- A SQL `WITH RECURSIVE` CTE walks the `REPLY_OF` edge table directly (depth cap 20) to find each comment's root Post. Each step is one indexed lookup on `idx_replyof_start`. LDBC reply chains are bounded ~8 across all SFs; the depth-20 cap is a safety margin.

The historical investigation notes (EXPLAIN ANALYZE traces, solutions explored) are preserved in the git commit history around the SQ2 investigation session.


## Implementation overview

Apache AGE lets us execute Cypher graph queries inside PostgreSQL via the
`cypher('graph_name', $$ ... cypher ... $$, $params)` SQL function. Our
implementation pattern is:

- **Each query runs as a single SQL statement.** Cypher is the inner DSL; the
  outer SQL wrapper handles things Cypher can't easily express.
- **Parameters are bound via PostgreSQL prepared statements.** This enables
  plan caching across calls with the same query shape — IC1, IC2, IC4–12, all
  IS, and all IU queries hit the cached path. IC3 is the only exception
  (its outer SQL contains parameter references in `SUM(CASE WHEN …)` that
  prevent prepared-statement caching for the wrapper).
- **Numeric properties (`id`, `creationDate`, `birthMonth`, `birthDay`) are
  stored as agtype integers**, not strings, so equality lookups
  (`MATCH (n {id: 933})`) match correctly. Storing them as strings would
  silently return zero rows from every lookup.
- **The label disjunction `(:Comment OR :Post)` is implemented as
  `UNION ALL` of two separate `cypher()` calls** — once for Comment and once
  for Post. AGE Cypher does not support multi-label MATCH, so the workload's
  many `Message` patterns expand to two-arm UNIONs. The PostgreSQL planner
  handles each arm independently, which is in fact faster than a single
  `WHERE label(m) IN ['Comment','Post']` would be.
- **Variable-length REPLY_OF traversal uses a SQL `WITH RECURSIVE` CTE** (depth
  cap 20) for IS2 and IS6. AGE's `[:REPLY_OF*]` planner enumerates all paths
  and joins late, which is much slower at scale. The SQL CTE walks the
  `REPLY_OF` edge table directly with one indexed lookup per step and avoids
  the unlabeled-intermediate seq-scan pathology (AGE-QUIRKS §9). IC12 still
  uses chained Cypher `OPTIONAL MATCH` for `IS_SUBCLASS_OF` (depth 6), which
  is acceptable because the tag-class hierarchy is shallow and the candidate
  set is small.
- **All sorting and `LIMIT` happens in the outer SQL** when results need to
  be combined across UNION arms. This lets the PostgreSQL planner pick the
  best sort strategy and avoids materialising large intermediate sets in
  Cypher.

The driver passes parameters as a single `agtype` JSON object to the inner
Cypher block; we never inline parameters as text into the Cypher source.

---

# Explanation on approach taken in different queries
This section can be consulted while reviewing the queries

## Complex queries (IC1–IC14)

### IC1 — friends with a given first name (3-hop)

Find people up to 3 friend-hops away whose first name matches a given value;
return their bio and education/work history. The current implementation
(V6) is a **genuine hybrid**:

- One Cypher call converts `$personId` to a graphid (`MATCH (p:Person {id: $personId}) RETURN id(p) LIMIT 1`).
- A SQL `WITH RECURSIVE` BFS walks `KNOWS` 1–3 hops via the `KNOWS` edge table (directed `-[:KNOWS]->` per AGE-QUIRKS §11), recording `MIN(dist)` per reachable person.
- A second Cypher call fetches all `firstName`-matching candidates (excluding `$personId`) with city, university, and company data via `OPTIONAL MATCH`.
- The outer SQL `JOIN`s the BFS reach table to the candidates, applies the firstName filter, sorts by `(distance, lastName, friendId)`, and takes the top 20.

The SQL BFS replaces the earlier three-separate-`cypher()` approach because
3-hop variable-length Cypher paths trigger path-enumeration at scale
(AGE-QUIRKS §4).

### IC2 — friends' recent messages

Most recent 20 messages by direct friends, posted before a given date.
Two-arm `UNION ALL` (Comment / Post). Sort and `LIMIT 20` in outer SQL.

### IC3 — friends in two countries

Friends (1- or 2-hop) who lived outside countries X and Y but posted from
both. **Four-arm UNION**: {1-hop, 2-hop} × {Comment, Post}. Cypher pulls
candidate (friend, country) rows; the **outer SQL aggregates with
`SUM(CASE WHEN country = X)` / `SUM(CASE WHEN country = Y)`** and keeps
friends with non-zero counts in both. Outer SQL aggregation lets the
PostgreSQL planner pick optimal join orders per branch — a structure AGE
Cypher cannot match natively. (Full-Cypher rewrite was investigated and
benchmarked at 2.6× slower for us)

> **Double-counting risk?** A friend reachable both directly and via 2-hop
> would appear in two arms. The 2-hop arm guards against this with
> `OPTIONAL MATCH (p)-[direct:KNOWS]->(friend) WHERE direct IS NULL`,
> excluding direct friends from the 2-hop set. So each friend appears in
> exactly one of the four arms.

### IC4 — new tags on friends' posts

Tags that appeared on friends' posts inside a date window but never before.
Single Cypher block computes `inWindow` and `preWindow` flags per
(post, tag), then aggregates: `WHERE postCount > 0 AND preWindowCount = 0`.

### IC5 — most-used forums by recent friends-of-friends

The current implementation (V11) is **hybrid**:

- One Cypher call returns the graphids of all 1- and 2-hop friends using a `UNION` inside the Cypher block: the 2-hop arm uses `OPTIONAL MATCH (p)-[direct:KNOWS]->(friend) WITH friend, direct WHERE direct IS NULL` to exclude direct friends (which are already covered by the 1-hop arm). Directed `-[:KNOWS]->` per AGE-QUIRKS §11.
- The SQL outer query JOINs to `HAS_MEMBER` (filtering `joinDate > $minDate`) and `Forum`, then LEFT JOINs to the `ForumMemberPostCount` side table (iter-2 aggregate, maintained by IU6) to get per-`(forum, member)` post counts in one index lookup.
- `GROUP BY (forum)` + `SUM(post_count)` + `ORDER BY postCount DESC, forumId ASC LIMIT 20` all happen in outer SQL.

### IC6 — co-occurring tags

Posts by friends-of-friends that carry both the input tag and at least one
other tag; rank co-occurring tags by post count. **Two-arm UNION** (1-hop /
2-hop). Each arm enforces *same-post* tag co-occurrence by re-MATCHing
`(post)-[:HAS_TAG]->(:Tag {name: $tagName})` after the first tag traversal.
Outer SQL sums per tag and breaks ties using `COLLATE "C"` for byte-order
sorting (matches LDBC reference).

> **Why `COLLATE "C"` for the tie-breaker?** PostgreSQL's default
> locale-aware collation sorts case- and locale-sensitively, which differs
> from the LDBC reference implementation's byte-wise comparison. Using
> `COLLATE "C"` produces stable byte-order results that match the
> validator. Same applies anywhere we tie-break on a text column.

### IC7 — most recent likers of own messages

For each person who liked one of `$personId`'s messages (Comments or Posts),
return their most recent like, the message liked, the latency in minutes
between message creation and like, and whether they're already a friend.
**Two-arm UNION** (Comment / Post). Outer SQL keeps the most-recent like
per liker via `DISTINCT ON (personId) ORDER BY personId, likeTime DESC`,
then re-sorts by `likeCreationDate DESC`.

### IC8 — recent replies to own messages

Most recent 20 replies (Comments) to messages authored by `$personId`.
The current implementation (V3) is **pure Cypher**: a single `cypher()` call
with an untyped `(message)` intermediate node (`(start:Person)<-[:HAS_CREATOR]-(message)<-[:REPLY_OF]-(reply:Comment)`).
AGE plans this internally as a UNION over labels, but the cost is bounded
to the seed person's messages so there is no seq-scan risk (AGE-QUIRKS §3).
`ORDER BY … LIMIT 20` is the final `RETURN`, which is safe. No outer UNION needed.

### IC9 — recent messages from friends and FOFs

Most recent 20 messages (before `$maxDate`) from friends or FOF. The current
implementation (V4) is **hybrid**:

- One Cypher call builds the full 1+2-hop friend graphid set using `UNION`
  inside Cypher (1-hop arm + 2-hop arm, both filtering `friend.id <> $personId`).
  The `UNION` (not `UNION ALL`) naturally deduplicates friends reachable via
  multiple paths. Typed-relationship negation `NOT (p)-[:KNOWS]-(f)` is
  rejected by the AGE parser (AGE-QUIRKS §10), so UNION deduplication is the
  workaround. Directed `-[:KNOWS]->` per AGE-QUIRKS §11.
- Two SQL CTEs (`top_comments`, `top_posts`) walk `idx_comment_date_id` /
  `idx_post_date_id` backwards from `< $maxDate` and semi-join against the
  friend set. The planner stops each index walk as soon as 20 friend-authored
  rows accumulate (Nested Loop Semi Join).
- Outer SQL combines both CTEs with `UNION ALL`, re-sorts by `creationDate
  DESC, messageId ASC`, and takes `LIMIT 20`.

### IC10 — common-interest friend recommendations

Friends-of-friends (excluding direct friends) born in a 30-day window
straddling a given month, ranked by how their post tags overlap with
`$personId`'s interests. The current implementation is **hybrid**:

- One Cypher call computes the surviving FoF set: 2-hop directed `KNOWS` traversal,
  birth-window filter using precomputed `birthMonth`/`birthDay` integer properties
  (AGE-QUIRKS §1), `OPTIONAL MATCH` direct-friend exclusion, and `IS_LOCATED_IN`
  city lookup. Returns graphids + scalar bio columns.
- The SQL outer query computes `commonInterestScore = 2×common_posts − total_posts`
  using: (a) `Post.creator_id` denorm (iter-1) for a fast per-friend post scan,
  (b) `HAS_TAG` + `HAS_INTEREST` indexed JOIN for common-interest posts, and
  (c) `PersonPostCount` side table (iter-2 aggregate) for total post count per
  person in a single index lookup.
- Directed `-[:KNOWS]->` per AGE-QUIRKS §11.

The 30-day birthday window crosses a month boundary, which Cypher cannot
compute natively (no datetime support). The `birthMonth` and `birthDay` integer
properties are precomputed at load time and also written by IU1 at creation time,
so newly inserted Persons are immediately queryable without backfill.

> **Does bidirectional KNOWS double-count FoFs?** No. The pattern
> `(p)-[:KNOWS]->(:Person)-[:KNOWS]->(friend)` traverses two distinct
> KNOWS edges; the intermediate node is a different Person each time, so
> the same FoF reached via two different intermediate friends *is* counted
> twice — but `WITH DISTINCT p, friend` before the city MATCH collapses
> these to one row per FoF.

### IC11 — friends working abroad

Friends (1- or 2-hop) who have worked at a company in country `$countryName`
since before `$workFromYear`. **Two-arm UNION**. Outer SQL sorts by
`(workFromYear ASC, friendId ASC, organizationName DESC)` and `LIMIT 10`.

### IC12 — replies to posts in a tag class hierarchy

Friends' Comments that reply to Posts whose tags belong to a given TagClass
or any subclass thereof. The current implementation is **hybrid**:

- One Cypher call resolves the root `TagClass` graphid by name.
- A SQL `WITH RECURSIVE` CTE walks the `TagClass.subclass_of_id` denorm column
  (iter-3) to collect all subclass ids.
- A `valid_tags` CTE filters `Tag` rows via `Tag.tagclass_id` denorm (iter-3).
- SQL JOINs use `Comment.creator_id` and `Comment.reply_of_id` denorm columns
  (iter-1) plus `HAS_TAG` for matched comments — no Cypher traversal required
  for the main join.
- A second Cypher call fetches direct friends of `$personId`.

This replaces the earlier single-Cypher approach that unrolled `IS_SUBCLASS_OF`
to 6 levels with chained `OPTIONAL MATCH`. The recursive CTE on denorm columns
is cleaner and scales better than Cypher unrolling.

> **Why depth cap in the CTE?** PostgreSQL's recursive CTE terminates naturally
> when no new rows are produced. No explicit depth cap is needed for `IS_SUBCLASS_OF`
> because the LDBC TagClass hierarchy is acyclic.

### IC13 / IC14 — shortest path queries

`SingleShortestPath` (IC13) and `AllShortestPaths` (IC14) require AGE
Cypher's `shortestPath()` / `allShortestPaths()` functions, **which are not
implemented in AGE 1.7**. The SQL files are placeholders — a Java handler
(`AgeIC13OperationHandler` / `AgeIC14OperationHandler`) returns the LDBC
"no path" sentinel value (`-1` for IC13, empty list for IC14). Both queries
are disabled in `benchmark.properties` / `validate.properties` until AGE
adds support.

For IC14, the LDBC spec has two valid result formats; both YAML files
(`-v1` weights inversely by reply count, `-v2` weights inversely by
liked-message count) are included for completeness.

---

## Short queries (IS1–IS7)

These run inline after each complex query (the LDBC "short read dissipation"
mechanic). They're cheap reads on identifier-keyed nodes.

### IS1 — person profile

Single `MATCH` on Person by id, plus `IS_LOCATED_IN -> City`.

### IS2 — recent messages with original post

Last 10 messages by `$personId` plus the root Post each is rooted in.
The current implementation (V2) is **hybrid**:

- Two Cypher calls (Comment branch, Post branch) each return up to 10 messages
  via `HAS_CREATOR`, with `ORDER BY … LIMIT 10` as a final `RETURN` (safe).
- A SQL `WITH RECURSIVE` CTE walks the `REPLY_OF` edge table to find each
  comment's root Post (depth cap 20; each step is one indexed lookup on
  `idx_replyof_start`).
- The outer SQL joins root graphids back to the `Post` and `Person` tables
  for author info, then re-sorts and returns the top 10.

See the IS2 implementation note at the top of this file for the history of
why the earlier 8-level Cypher unroll was replaced.

### IS3 — friends sorted by friendship date

Direct friends ordered by friendship `creationDate` desc, then `friendId`.
Single `MATCH` with sort inside Cypher.

### IS4 — message content

Get content + creation date for one message. **Two-arm UNION** (Comment /
Post) since the input id can be either label.

### IS5 — message creator

Same shape as IS4 — two-arm UNION → return the author.

### IS6 — message's forum and moderator

For a given message, walk back through the reply chain to find the root Post,
then return its containing Forum and moderator. The current implementation is
**pure SQL** — no Cypher calls:

- A materialized CTE seeds from `Post` or `Comment` (whichever matches `$messageId`).
- A `WITH RECURSIVE` CTE walks `REPLY_OF` up to depth 20 via `idx_replyof_start`
  to find the root Post (Comments have no outgoing `REPLY_OF`; the walk terminates naturally).
- The outer SQL JOINs `CONTAINER_OF` → `Forum` → `HAS_MODERATOR` → `Person`
  using indexed B-tree joins on known graphids.

The query header explicitly documents that this should NOT be converted to a
Cypher call — the SQL approach is structurally sound and adding Cypher overhead
would provide no benefit.

### IS7 — replies to a message

Direct replies to a given message, with each replier and a flag for whether
they know the original author. **Two-arm UNION** (Comment / Post) so the
input id can be either label.

---

## Update operations (IU1–IU8)

These are write transactions. Most contain a single `cypher()` call that
`MATCH`es the referenced nodes and `CREATE`s the new edges/nodes. IU7 is
the exception — it uses two `cypher()` calls to avoid an AGE MVCC concurrency
bug (see IU7 below and the file header comment). Several IUs also include a
SQL `UPDATE` after the Cypher `CREATE` to maintain denorm columns (iter-1).

### IU1 — add Person

Creates a Person, edges to their City, all `HAS_INTEREST` tag edges (via
`UNWIND $tagIds`), and all `STUDY_AT` / `WORK_AT` organization edges. We
also write the precomputed `birthMonth` / `birthDay` integer properties at
creation time so newly added persons are immediately queryable by IC10
without a backfill.

> **Are the per-tag MATCHes inside `UNWIND` an N+1?** Each iteration of the
> UNWIND issues a `MATCH (t:Tag {id: tagId})` against the GIN-on-Tag.properties
> index — a single index lookup per tag. Tag count per Person is bounded
> in LDBC (typically &lt;20), so the total cost is negligible compared to
> the Person creation. Same pattern in IU4, IU6, IU7.

### IU2 — Person likes Post

Creates a `LIKES` edge from Person to Post with the like's creationDate.

### IU3 — Person likes Comment

Same as IU2 but for Comment.

### IU4 — add Forum

Creates a Forum, its `HAS_MODERATOR` edge to the moderator Person, and one
`HAS_TAG` edge per provided tag id (via `UNWIND $tagIds`).

### IU5 — add Forum membership

Creates a `HAS_MEMBER` edge from Forum to Person with `joinDate`.

### IU6 — add Post

Creates a Post, edges to its author (`HAS_CREATOR`), forum
(`CONTAINER_OF`), and country (`IS_LOCATED_IN`), plus all `HAS_TAG` edges
(via `UNWIND $tagIds`). The `content` and `imageFile` properties are
stored as `null` when given as empty strings (LDBC schema allows either,
not both — we never store empty strings as content).

### IU7 — add Comment

Creates a Comment with `HAS_CREATOR`, `REPLY_OF`, `IS_LOCATED_IN`, and
`HAS_TAG` edges. The implementation uses **two `cypher()` calls** split to
avoid an AGE MVCC concurrency bug (issue #1954):

- **Call 1**: resolves the `replyTo` target using `OPTIONAL MATCH (rp:Post {id: $replyToId})` + `OPTIONAL MATCH (rc:Comment {id: $replyToId})` with `COALESCE(rp, rc) AS replyTo` — typed OPTIONAL MATCH avoids the untyped-intermediate pathology (AGE-QUIRKS §9). Creates the Comment vertex plus `HAS_CREATOR`, `REPLY_OF`, and `IS_LOCATED_IN` edges.
- **Call 2**: MATCHes the newly committed Comment, `UNWIND $tagIds`, and creates `HAS_TAG` edges. Runs in a fresh visibility window where the Comment is already visible, avoiding the MVCC trigger.
- A SQL `UPDATE` maintains `Comment.{creator_id, reply_of_id, country_id}` denorm columns (iter-1).

### IU8 — add Friendship

Creates two `KNOWS` edges (A→B and B→A) so subsequent reads find the
friendship in either direction without changing query patterns. The
graph stores friendships bidirectionally throughout.

> **Why bidirectional storage rather than direction-agnostic MATCH?**
> Cypher's `(a)-[:KNOWS]-(b)` (no arrow) would handle either direction
> at read time, but AGE compiles it as a UNION of forward and reverse
> traversals — doubling the planner work on every IC1/IC3/IC10/etc.
> Storing both directions and using `(a)-[:KNOWS]->(b)` everywhere
> halves traversal cost at the price of 2× edge-table size.

---

