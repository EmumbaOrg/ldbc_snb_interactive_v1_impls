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



### Known performance issue: IS2 (LdbcShortQuery2PersonPosts)

**TL;DR.** IS2 is the slowest query in the workload by an order of magnitude.
At SF0.1 it averages ~8.4 s per invocation (p99 ~16.9 s), versus <50 ms p50
for sibling short reads (IS1, IS3, IS5, IS7). On a real benchmark run this
is the single largest contributor to LDBC schedule-audit failures
("TOO_MANY_LATE_OPERATIONS"). **This is a known limitation of AGE 1.6's
planner, not an implementation bug — do not interpret high IS2 latency as
a regression.**

#### Reference query

`queries/interactive-short-2.sql`:

```sql
SELECT * FROM (
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Comment)
    WITH msg ORDER BY msg.creationDate DESC, msg.id ASC LIMIT 10
    MATCH (msg)-[:REPLY_OF]->(r1)
    OPTIONAL MATCH (r1)-[:REPLY_OF]->(r2)
    OPTIONAL MATCH (r2)-[:REPLY_OF]->(r3)
    OPTIONAL MATCH (r3)-[:REPLY_OF]->(r4)
    OPTIONAL MATCH (r4)-[:REPLY_OF]->(r5)
    OPTIONAL MATCH (r5)-[:REPLY_OF]->(r6)
    OPTIONAL MATCH (r6)-[:REPLY_OF]->(r7)
    OPTIONAL MATCH (r7)-[:REPLY_OF]->(r8)
    WITH msg, coalesce(r8, r7, r6, r5, r4, r3, r2, r1) AS rootPost
    MATCH (post:Post)-[:HAS_CREATOR]->(author:Person)
    WHERE id(post) = id(rootPost)
    RETURN msg.id, coalesce(msg.content, msg.imageFile), msg.creationDate,
           post.id, author.id, author.firstName, author.lastName
  $$) AS (...)
  UNION ALL
  -- Post branch (fast — runs in ~10 ms, not the cost center)
  SELECT * FROM cypher('$graphName', $$
    MATCH (p:Person {id: $personId})<-[:HAS_CREATOR]-(msg:Post) ...
  $$) AS (...)
) all_msgs ORDER BY messageCreationDate DESC, messageId ASC LIMIT 10;
```

The Comment branch must walk up the REPLY_OF chain to find the original
root Post. The chain is structurally bounded — every Comment ultimately
roots at a Post — so the spec uses an 8-level `OPTIONAL MATCH` ladder to
unwind it.

#### Root cause (verified via EXPLAIN ANALYZE)

The 8-level ladder leaves intermediate variables `r1` … `r8` **unlabeled**.
AGE's planner cannot infer label types from a graphid even though the
graphid encoding (`label_id << 48 | entry_id`) makes it possible. So at
each of the 8 levels it produces this Parallel Append:

```
Parallel Append over all 11 vertex labels at every OPTIONAL MATCH level
├─ Parallel Seq Scan on "Comment"      151,043 rows
├─ Parallel Seq Scan on "Post"          67,850 rows
├─ Parallel Seq Scan on "Tag"           16,080 rows
├─ Parallel Seq Scan on "Forum"         13,750 rows
├─ Parallel Seq Scan on "University"     6,380 rows
├─ Parallel Seq Scan on "Person"         1,528 rows
├─ Parallel Seq Scan on "Company"        1,575 rows
├─ Parallel Seq Scan on "City"           1,343 rows
├─ Parallel Seq Scan on "Country"          111 rows
├─ Parallel Seq Scan on "TagClass"          71 rows
└─ Parallel Seq Scan on "Continent"          6 rows
```

Per invocation: ~327 K vertex rows × 8 levels = ~2.6 M rows of vertex
scans plus 8 × Parallel Seq Scan on REPLY_OF (151 K rows) — for chains
that, in real LDBC data, are rarely deeper than 1–3 hops.

A second issue compounds it: after the climb, the query does
`MATCH (post:Post) WHERE id(post) = id(rootPost)`. The agtype-wrapping
(`age_id(_agtype_build_vertex(post.id, …, post.properties))`) on both
sides of the equality defeats the `idx_post_id` B-tree. The planner
falls back to `Seq Scan on "Post"` (135 K rows at SF0.1) hash-joined
against the 10-row rootPost set.

EXPLAIN ANALYZE (SF0.1, heavy poster id 2199023256816, single thread,
warm cache) — total **2768 ms**. About 2.4 s in the OPTIONAL MATCH
ladder, ~200 ms in the Post seq scan, ~100 ms in the rest.

#### Solutions explored and why each was rejected

| Approach | Result | Status |
|---|---|---|
| Add label predicates `(r1:Comment)` to climb steps | AGE rejects with "multiple labels for variable not supported" | ❌ syntactically blocked |
| Variable-length pattern `[:REPLY_OF*1..8]` | AGE produces a 452 M-row Cartesian estimate; ~2.55 s execution | ❌ no improvement |
| Drop redundant `MATCH (post:Post) WHERE id()=id()` block | ~10% win (2768 → 2507 ms); ladder still dominates | ❌ insufficient |
| Denormalize `rootPostId` on each Comment at preprocess time | Verified **30× speedup** (88 ms) end-to-end with `MATCH (post:Post {id: msg.rootPostId})` lookup hitting `gin_post`. NumPy-backed chain walker. | ⚠️ scales to ~SF300 on a 32 GB host; SF1000 needs ~25 GB resident + ~75 GB transient peak during sort, exceeds the benchmark host. Preprocess cannot be moved to the DB host (operational constraint). |
| Denormalize `rootPostId` post-load on the DB host (recursive CTE + UPDATE) | Bounded by indexed REPLY_OF lookups; works at all SFs on the 32 vCPU / 256 GB DB host | ⚠️ adds ~30–60 minutes to load time at SF1000; UPDATE creates dead tuples on the Comment table requiring extra VACUUM cycle |

The denormalization approaches both work technically. They were not
adopted because (a) the load-time cost at large SF was deemed too high
relative to the benefit, and (b) the implementation complexity and
operational coupling (preprocess host vs. DB host vs. file shipping)
weren't worth the latency improvement at this stage.

#### Open path

The clean fix is in AGE itself: teach the planner to use the graphid's
embedded `label_id` (high 16 bits) to prune the all-label Append when
`MATCH (n)-[:R]->(m)` references an unlabeled `m`. With that planner
change, the existing 8-level OPTIONAL MATCH would hit only the relevant
label table at each level and complete in tens of milliseconds with no
denormalization required.

Until that lands upstream, **expect IS2 latency to dominate the workload
mix**. When reporting benchmark numbers, call this out explicitly so
readers don't conclude that AGE is intrinsically slow on neighborhood
reads — IS1, IS3, IS5, IS7 (which don't traverse REPLY_OF chains)
demonstrate the actual short-read latency profile.

For investigation continuity, the EXPLAIN ANALYZE traces and exploration
notes are in this repo's commit history around the SQ2 investigation
session. Reproduction of the 2768 ms baseline:

```sql
LOAD 'age'; SET search_path = ag_catalog, public;
EXPLAIN (ANALYZE, BUFFERS) <contents of interactive-short-2.sql with
                            $graphName='ldbc_snb' and $personId substituted
                            for any heavy-poster id, e.g. 2199023256816
                            at SF0.1>;
```




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
- **Variable-length REPLY_OF traversal is unrolled to a fixed depth (8) with
  chained `OPTIONAL MATCH`** — see IS2/IS6. AGE's `[:REPLY_OF*]` planner
  enumerates all paths first and joins late, which is much slower than the
  unrolled form for the typical reply-thread depth in the dataset.
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
return their bio and education/work history. We run **three separate
`cypher()` blocks** for the 1-hop, 2-hop, and 3-hop neighborhoods, tag each
with its hop distance, then `UNION ALL` and **deduplicate by friend ID
keeping the smallest hop**. Sort by `(distance, lastName, friendId)` and
take the top 20 in outer SQL.

> **Why UNION ALL + dedup, not three exclusive arms?** Excluding 1-hop friends
> from the 2-hop arm would require an outer `WHERE NOT EXISTS` against the
> 1-hop result set — adding a join and a probe per row. UNION ALL with
> outer `DISTINCT ON (friendId) ORDER BY distance` is one extra sort, no
> join, and the planner picks an index-scan for the sort.

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

For each (friend, forum) where the friend joined after `minDate`, count the
friend's posts in that forum. **Two-arm UNION** for 1-hop and 2-hop friends.
Outer SQL deduplicates `(friendId, forumId)` pairs (a friend reachable both
ways shouldn't be double-counted) and sums posts per forum.

> **Why dedup outside instead of `WHERE direct IS NULL` like IC3?** The
> 2-hop arm here filters by `friend.id <> $personId` and de-dupes friend via
> `WITH DISTINCT friend`, but does *not* exclude direct friends — the LDBC
> spec wants both 1-hop and 2-hop friends counted, just not double-counted.
> So we dedup `(friendId, forumId)` in outer SQL, which is cheaper than a
> NOT-EXISTS join inside Cypher.

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
**Two-arm UNION** because the original message can be a Comment or a Post.
Sort and `LIMIT 20` in outer SQL.

### IC9 — recent messages from friends and FOFs

Most recent 20 messages (before `$maxDate`) from friends *or*
friends-of-friends. **Four-arm UNION**: {1-hop, 2-hop} × {Comment, Post}.
The 2-hop arms `OPTIONAL MATCH` a direct edge and exclude
`direct IS NULL` to keep the spec's "FoF excludes direct friends" rule.

### IC10 — common-interest friend recommendations *(Phase F: precomputed)*

Friends-of-friends (excluding direct friends) born in a 30-day window
straddling a given month, ranked by how their post tags overlap with
`$personId`'s interests. **Single Cypher block** — no UNION needed.

The 30-day birthday window crossed a month boundary, which Cypher cannot
compute natively (no datetime support). We **precomputed `birthMonth` and
`birthDay` integer properties on every Person at data load time** =, so the window check becomes a simple
integer comparison. This eliminated a per-call `EXTRACT(...)` in outer SQL
and lets IC10 use the cached prepared statement path. IC10 saw 40% latency improvement after this. 
Disclaimer, we are not sure if this is allowed with ldbc. If in future, we go for audit, this may needs to be changed. However, the alternative approach we had was much slower. 

> **What about Persons added by IU1 mid-benchmark?** The IU1 query
> (add-Person) also writes `birthMonth` and `birthDay` at creation time,
> derived in the Java handler from the LDBC `birthday` field. So newly
> inserted Persons are immediately queryable by IC10 without any backfill.

> **Does bidirectional KNOWS double-count FoFs?** No. The pattern
> `(p)-[:KNOWS]->(:Person)-[:KNOWS]->(friend)` traverses two distinct
> KNOWS edges; the intermediate node is a different Person each time, so
> the same FoF reached via two different intermediate friends *is* counted
> twice — but the `WITH DISTINCT p, friend, city` collapses these to one
> row per (FoF) before the post traversal.

### IC11 — friends working abroad

Friends (1- or 2-hop) who have worked at a company in country `$countryName`
since before `$workFromYear`. **Two-arm UNION**. Outer SQL sorts by
`(workFromYear ASC, friendId ASC, organizationName DESC)` and `LIMIT 10`.

### IC12 — replies to posts in a tag class hierarchy

Friends' Comments that reply to Posts whose tags belong to a given TagClass
or any subclass thereof. **Single Cypher block**, but the subclass hierarchy
is **unrolled to 6 levels with chained `OPTIONAL MATCH IS_SUBCLASS_OF`**
because variable-length subclass paths are slow in AGE 1.6. The WHERE clause
checks if `tc` or any ancestor matches the given base class.

> **Why depth 6?** The LDBC reference TagClass hierarchy has a maximum
> depth of 4 (Thing → Person → Athlete → SoccerPlayer). Depth 6 gives
> headroom without measurable cost — each `OPTIONAL MATCH` becomes a
> nullable join the planner short-circuits when prior levels return null.
> If a real dataset had a deeper hierarchy, queries would silently miss
> the deepest classes; matches LDBC spec assumptions.

### IC13 / IC14 — shortest path queries

`SingleShortestPath` (IC13) and `AllShortestPaths` (IC14) require AGE
Cypher's `shortestPath()` / `allShortestPaths()` functions, **which are not
implemented in AGE 1.6**. The SQL files are placeholders — a Java handler
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
**Two-arm UNION**: Comment branch unrolls REPLY_OF to depth 8 with chained
`OPTIONAL MATCH` and uses `coalesce(r8, r7, …, r1)` to find the root; Post
branch is direct (a Post is its own root). The unrolled walk is much
faster than `[:REPLY_OF*]` because AGE evaluates variable-length paths
without predicate pushdown.

> **Why depth 8?** LDBC reference data has reply chains observed up to
> depth 7 at SF1000; depth 8 is one level of headroom. A reply chain
> deeper than 8 would silently match the deepest hop's value as the
> root — acceptable per the LDBC spec assumption that chains are
> bounded.

### IS3 — friends sorted by friendship date

Direct friends ordered by friendship `creationDate` desc, then `friendId`.
Single `MATCH` with sort inside Cypher.

### IS4 — message content

Get content + creation date for one message. **Two-arm UNION** (Comment /
Post) since the input id can be either label.

### IS5 — message creator

Same shape as IS4 — two-arm UNION → return the author.

### IS6 — message's forum and moderator

For a given message, walk back through the reply chain (8-deep
`OPTIONAL MATCH`) to find the root Post, then jump to its containing Forum
and the forum's moderator. **Two-arm UNION** (Comment with reply-walk /
Post direct), with a `src` tag column so outer SQL can prefer the comment
branch when both rows are present.

> **Why a `src` tag column rather than relying on label disjointness?**
> The input `$messageId` is unique across Comments and Posts in LDBC, so
> exactly one arm should match. The `src ORDER BY` is defensive — it
> guarantees deterministic single-row output if a future dataset
> violated that uniqueness, costing one extra integer comparison.

### IS7 — replies to a message

Direct replies to a given message, with each replier and a flag for whether
they know the original author. **Two-arm UNION** (Comment / Post) so the
input id can be either label.

---

## Update operations (IU1–IU8)

These are write transactions. Each is a single `cypher()` call that
`MATCH`es the referenced nodes and `CREATE`s the new edges/nodes.

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

Creates a Comment with `HAS_CREATOR` to author, `REPLY_OF` to its target
(which can be a Comment or a Post — handled by an unlabelled MATCH on the
target id), `IS_LOCATED_IN` to country, and `HAS_TAG` per tag.

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

