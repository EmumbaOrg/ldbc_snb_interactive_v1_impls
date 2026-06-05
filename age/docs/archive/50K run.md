# AGE SF10 Benchmark Run 1 — 50k ops (2026-05-15)

  ## Run Configuration

  | Parameter | Value |
  |---|---|
  | Scale Factor | SF10 |
  | Operation Count | 50,000 |
  | Thread Count | 16 |
  | Warmup Ops | 5,000 |
  | Time Compression Ratio | 0.001 |
  | Database | Apache AGE (`AgeInteractiveDb`) |
  | Endpoint | Azure West US 3 (HorizonDB) |
  | Disabled Queries | Q13, Q14 |

  ---

  ## Overall Results

  | Metric | Value |
  |---|---|
  | Total Operations | 50,017 |
  | Total Duration | 3,000,517 ms (~50 min) |
  | Throughput | **16.67 ops/sec** |
  | Schedule Audit | **FAILED** |

  ---

  ## Query Performance (Mean Latency, ms)

  ### Complex Reads (Q1–Q12)

  | Query | Count | Mean (ms) | p50 | p90 | p99 | Max |
  |---|---|---|---|---|---|---|
  | Q1 | 459 | 437 | 450 | 601 | 693 | 751 |
  | Q2 | 323 | **9** | 3 | 24 | 50 | 83 |
  | Q3 | 130 | **2,034** | 2,101 | 3,566 | 4,225 | 4,403 |
  | Q4 | 332 | 173 | 175 | 244 | 296 | 622 |
  | Q5 | 182 | 252 | 284 | 421 | 475 | 497 |
  | Q6 | 50 | 318 | 322 | 398 | 443 | 443 |
  | Q7 | 221 | 138 | 96 | 154 | 238 | **7,297** |
  | Q8 | 797 | **31** | 28 | 49 | 95 | 151 |
  | Q9 | 42 | 366 | 350 | 460 | 485 | 485 |
  | Q10 | 342 | 754 | 738 | 969 | 1,105 | 1,267 |
  | Q11 | 629 | 373 | 351 | 526 | 663 | 716 |
  | Q12 | 272 | 631 | 457 | 619 | 786 | **46,418** |

  ### Short Reads (SQ1–SQ7)

  | Query | Count | Mean (ms) | p50 | p99 |
  |---|---|---|---|---|
  | SQ1 PersonProfile | 4,721 | 4.4 | 1 | 53 |
  | SQ2 PersonPosts | 4,721 | 42.7 | 38 | 136 |
  | SQ3 PersonFriends | 4,721 | 6.3 | 3 | 53 |
  | SQ4 MessageContent | 4,749 | 5.7 | 1 | 59 |
  | SQ5 MessageCreator | 4,749 | 9.6 | 12 | 45 |
  | SQ6 MessageForum | 4,749 | 3.6 | 2 | 38 |
  | SQ7 MessageReplies | 4,749 | 14.5 | 15 | 51 |

  ### Updates (U1–U8)

  | Update | Count | Mean (ms) | p50 | p99 | Max |
  |---|---|---|---|---|---|
  | U1 AddPerson | 4 | 85 | 45 | 197 | 197 |
  | U2 AddPostLike | 1,879 | 158 | 155 | 317 | 621 |
  | U3 AddCommentLike | 2,368 | **413** | 413 | 804 | 1,083 |
  | U4 AddForum | 65 | 29 | 19 | 74 | 511 |
  | U5 AddForumMembership | 5,809 | **12** | 11 | 22 | 555 |
  | U6 AddPost | 790 | 157 | 21 | 1,595 | 2,533 |
  | U7 AddComment | 1,924 | **791** | 9 | 7,132 | **10,246** |
  | U8 AddFriendship | 240 | 9 | 9 | 28 | 66 |

  ---

  ## Key Issues

  1. **Schedule Audit FAILED** — 16,800 late operations against a 2,500 tolerance limit. Nearly every
     operation type exceeded the late count threshold. Mean scheduling delay was ~390 seconds,
     indicating the system was severely behind schedule throughout the run.

  2. **Q12 extreme outlier** — p99.9 of 46,418 ms (~46 sec) vs. a p99 of 786 ms. Likely a single
     pathological execution.

  3. **U7 (AddComment) high variance** — Mean of 791 ms with std_dev of 1,490 ms and a max of
     10,246 ms. The p50 is only 9 ms but p75 jumps to 1,505 ms — a bimodal distribution suggesting
     inconsistent execution plans or locking.

  4. **U6 (AddPost) tail latency** — p90 is 363 ms but p95 jumps to 953 ms and p99 to 1,595 ms,
     indicating heavy tail latency under load.

  5. **Q3 slowest complex read** — ~2,034 ms mean, consistent with its expensive friend-of-friend
     traversal pattern.

  6. **Short reads are healthy** — all SQ queries complete under 50 ms mean.

  ---

  ## Per-query implementation vs Neo4j

  One row per query (all 27 enabled operations). The "Implementation style"
  column says whether the query is *Pure Cypher* (single `cypher()` call,
  no outer SQL beyond the result projection), *Hybrid* (multiple `cypher()`
  calls and/or outer SQL CTEs/joins), or *Hybrid + denorm* (also relies on
  one or more precomputed side tables — `MessageByCreator`,
  `ForumMemberPostCount`, `PersonPostCount`, `CommentRootPost`, etc.).
  The "Structural difference vs Neo4j" column names the specific AGE 1.6
  limitation that forces the rewrite, with the `AGE-QUIRKS.md` §
  cross-reference where applicable.

  | Query | Mean (ms) | Implementation style | Structural difference vs Neo4j causing the cost |
  |---|---|---|---|
  | Q1 | 437 | Hybrid — 3 Cypher calls (1-hop / 2-hop / 3-hop arms) + outer SQL `UNION ALL` + `DISTINCT ON` for min-distance dedup | Neo4j uses `[:KNOWS*1..3]` variable-length path with native BFS. AGE can't push predicates into VLE (§4), so we unroll 1/2/3-hop as 3 separate Cypher calls — each pays per-`cypher()` ceremony (~50–150 ms × 3). |
  | Q2 | 9 | Hybrid + denorm — 1 Cypher call (friend set) + outer SQL `LATERAL` top-N per friend from `MessageByCreator` side table | Neo4j matches `(:Message)` natively (multi-label). AGE has no multi-label MATCH (§3). Without the denorm: per-friend Comment+Post UNION scans every friend's messages before global top-20 — 193× slower at SF3 in measurement. |
  | Q3 | 2,034 | Hybrid — 3 Cypher calls (country-first seed + 1-hop `EXISTS` + 2-hop `EXISTS { KNOWS-KNOWS }` per message-creator) | Neo4j: one MATCH with multi-label `(:Message)` + country filter. AGE: UNION ALL Comment/Post (§3); 2-hop EXISTS runs per surviving (country, msg) row giving O(M×D) probes — may regress further at SF1000. |
  | Q4 | 173 | Hybrid — 2 Cypher calls inside `MATERIALIZED` CTEs + outer SQL `NOT EXISTS` hash anti-join on bigint tag_id; `COLLATE "C"` on tag name | Neo4j: native date arithmetic + `NOT (tag IN preWindowTags)`. AGE: no datetime (§1) forces bigint compare; `agtype_in_operator` is linear so rewritten as outer-SQL Hash Anti-Join; default `en_US.UTF-8` collation flips tags-with-underscore ordering vs LDBC oracle. |
  | Q5 | 252 | Hybrid + denorm — 1 Cypher call (1+2-hop friend set via fixed-depth MATCH UNION) + outer SQL on `ForumMemberPostCount`, `HasMemberSide`, `ForumSide` | Neo4j: clean OPTIONAL MATCH `(forum)-[:CONTAINER_OF]->(post)-[:HAS_CREATOR]->(friend)` with count. AGE compiles this as parallel hash join over full Post × HAS_CREATOR × CONTAINER_OF cross-product — **33,350 ms at SF3 pre-denorm**; 252 ms only because per-(forum, member) post count is precomputed. |
  | Q6 | 318 | Hybrid — 2 Cypher calls (direct-friend branch + FoF branch) with explicit `WITH` between every MATCH segment | Neo4j: single `(:Message)` walk with co-occurring-tag aggregation. AGE: UNION ALL across labels (§3); silent zero-row bug on consecutive reverse-arrow `<-`/`<-` matches forces verbose `WITH` between every hop. |
  | Q7 | 138 | Hybrid — 2 Cypher calls (Comment+Post arms) with `collect+UNWIND` barrier; `NOT EXISTS { (p)-[:KNOWS]->(liker) }` for isNew flag | Neo4j: `NOT (p)-[:KNOWS]-(liker)` pattern negation as one expression. AGE parser rejects `NOT (p)-[:TYPED_REL]-(n)` (§10) so we use `NOT EXISTS`; `collect+UNWIND` barrier prevents planner from full-scanning the LIKES edge table — 124× speedup vs OPTIONAL MATCH form. |
  | Q8 | 31 | Pure Cypher — single call, untyped `message` intermediate matches both Comment and Post implicitly | Closest to Neo4j shape. Cost bounded by seed Person's messages so no seq-scan risk. The flat ~30 ms is mostly per-`cypher()` ceremony (parser cache miss + agtype boxing + JDBC text-mode fetch); Neo4j answers equivalent <5 ms. |
  | Q9 | 366 | Hybrid + denorm — 1 Cypher call (1+2-hop friend ids) + outer SQL `LATERAL` per-friend top-20 by date DESC on `MessageByCreator` + `PersonSide` for names | Neo4j: VLE `[:KNOWS*1..2]` for friend+FoF + `(:Message)` multi-label. AGE: §3 + §4 force 1-hop UNION 2-hop fixed-depth; per-friend top-K needs the date-indexed denorm to avoid scanning all friend-messages. |
  | Q10 | 754 | Hybrid + heavy denorm — 1 Cypher call with `NOT EXISTS` direct-friend exclusion + precomputed `birthMonth`/`birthDay`; outer SQL uses `PersonPostCount`, `MessageByCreator`, `creator_id` | Neo4j: `datetime()` arithmetic on `birthday` + clean `(:Post)-[:HAS_TAG]->(tag)<-[:HAS_INTEREST]-(p)` interest score. AGE: no datetime (§1); planner threshold-flips at SF3 to merge-join over full 9 M-row `IS_LOCATED_IN` table once friend set crosses ~300 — only fixable via `collect+UNWIND` barrier + side tables. |
  | Q11 | 373 | Hybrid — 2 Cypher calls (direct-friend + FoF) with fixed-depth MATCH; outer SQL `ORDER BY organizationName ::text COLLATE "C"` tie-break | Neo4j: VLE `[:KNOWS*1..2]` + native pattern negation. AGE: undirected `-[:KNOWS]-` does full edge-table scan (§11) so we rewrite directed; no VLE pushdown; default PG collation flips company-name sort vs LDBC oracle. |
  | Q12 | 631 | Hybrid — 2 Cypher calls (Phase 1+2 builds `valid_tag_ids`; Phase 3 traversal) + outer SQL `MATERIALIZED` CTE for Hash-IN join on bigint | Neo4j: VLE `[:IS_SUBCLASS_OF*1..]` + single-pass aggregation. AGE: §4 + §9 composite-type collision on `*1..` forces explicit d1–d6 ladder; `WHERE tag.id IN <aggregate-output>` can't push past Cypher aggregate boundary, so planner materialises 743 K-row post-tag pipeline and post-filters 99.97 % of rows — driver of the 46 sec p99.9 outlier. |
  | SQ1 | 4.4 | Pure Cypher — single call | Closest to Neo4j shape; ~4 ms is per-`cypher()` ceremony, not query work. Neo4j answers equivalent <1 ms. |
  | SQ2 | 42.7 | Hybrid + denorm — 2 Cypher calls + SQL `WITH RECURSIVE` on `CommentRootPost` denorm; `MessageByCreator` for top-10 by date | Neo4j: `[:REPLY_OF*0..]` finds root post in one VLE expression. AGE: §4 + §9 force explicit recursive CTE (depth cap 20); pre-denorm SF3 was 7,538 ms — current 43 ms requires both denorm tables. |
  | SQ3 | 6.3 | Pure Cypher — single call | Single-hop KNOWS; pure Cypher works fine. ~6 ms is per-`cypher()` overhead vs Neo4j ~1 ms native graph access. |
  | SQ4 | 5.7 | Hybrid — 2 Cypher calls + outer SQL `UNION ALL` across Comment/Post arms | Neo4j: multi-label MATCH `(m:Comment|Post {id: $msgId})`. AGE: no multi-label MATCH (§3) so two cypher() calls. Was **4,737 ms before the parameterised-path reversal** (§15) — generic plan locked in Seq Scan on 6.4 M-row Comment label table. |
  | SQ5 | 9.6 | Hybrid — 2 Cypher calls + outer SQL `UNION ALL` across Comment/Post | Same root cause as SQ4 — multi-label MATCH absent forces two cypher() calls. Was 3,700 ms baseline before parameterised rewrite reduced it to 89 ms. |
  | SQ6 | 3.6 | Hybrid + denorm — 2 Cypher calls + SQL `WITH RECURSIVE` on `CommentRootPost` | Neo4j: VLE `[:REPLY_OF*0..]` then one hop to Forum. AGE: §4 forces SQL recursive CTE; denorm table avoids per-call CTE-from-scratch cost. |
  | SQ7 | 14.5 | Hybrid — 2 Cypher calls (Comment + Post branches) with per-arm `knows` flag computation | Neo4j: multi-label `(m:Comment|Post)` + native `EXISTS { (m_author)-[:KNOWS]-(replier) }`. AGE: §3 forces UNION ALL across labels with per-arm knows probe. |
  | U1 | 85 | Hybrid + denorm maintenance — 2 Cypher calls; precomputed `birthMonth`/`birthDay` at insert; `PersonPostCount`/`PersonSide` upserts | Neo4j: single `CREATE (p:Person)-[:IS_LOCATED_IN]->(c) ...` block. AGE: no `FOREACH` (cannot fold multi-edge insert cleanly); empty-UNWIND-collapse forces each optional edge list into its own Cypher call; manual side-table maintenance. **MVCC race high-susceptibility** (many CREATEs in one txn — `AGE-1.6-MVCC-BUG.md`). |
  | U2 | 158 | Pure Cypher — single call, single LIKES edge | Closest to Neo4j shape; cost dominated by JDBC handler ceremony + connection-acquire (96 ms acquire vs 0.1 ms server-side work in Tier B measurements), not the graph engine. |
  | U3 | 413 | Pure Cypher — single call, single LIKES edge | Same shape as U2; the 413 ms p50 is **cold-buffer GIN containment on 6.4 M-row Comment label table** to resolve the target Comment by id — agtype+GIN storage cost Neo4j doesn't pay. |
  | U4 | 29 | Hybrid + denorm maintenance — 2 Cypher calls; `ForumSide` upsert | Neo4j: single CREATE block for Forum + HAS_MODERATOR + HAS_TAG. AGE: split into multiple Cypher calls due to empty-UNWIND-collapse; side-table upsert in outer SQL. |
  | U5 | 12 | Hybrid + denorm maintenance — 2 Cypher calls; `HasMemberSide` upsert | Neo4j: single edge CREATE. AGE: cheap edge insert (12 ms) — gap vs Neo4j is per-`cypher()` ceremony + side-table maintenance, not graph work. |
  | U6 | 157 | Hybrid + heavy denorm maintenance — 2 Cypher calls; `ForumMemberPostCount`, `MessageByCreator`, `PersonPostCount` upserts; `creator_id`/`forum_id` writes | Neo4j: single CREATE block for Post + 4 edges. AGE: Cypher split for empty-UNWIND avoidance; 3 side-table upserts; **bimodal p50/p99 (21 → 1,595 ms) = MVCC race triggering retry path** on high-CREATE-count IUs (`AGE-1.6-MVCC-BUG.md`). |
  | U7 | 791 | Hybrid + heavy denorm maintenance — 3 Cypher calls; `CommentRootPost`/`MessageByCreator` upserts; `creator_id`/`reply_of_id`/`country_id` writes; `ON CONFLICT DO NOTHING` | Same architecture as U6 + REPLY_OF root-post resolution (recursive CTE). **Most-affected query by the MVCC race historically** (`AGE-1.6-MVCC-BUG.md` table). The 9 ms p50 vs 7,132 ms p99 bimodal split is the MVCC retry-or-skip path — Neo4j has no equivalent visibility race. |
  | U8 | 9 | Pure Cypher — single call, symmetric KNOWS pair (creates both directed edges) | Neo4j: single CREATE of one undirected edge. AGE: stores KNOWS bidirectionally to compensate for undirected-scan pathology (§11). Cost is similar to Neo4j. |