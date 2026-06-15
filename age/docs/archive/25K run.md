# AGE SF10 Benchmark Run 7 — 25k ops (2026-05-15)

  ## Run Configuration

  | Parameter | Value |
  |---|---|
  | Scale Factor | SF10 |
  | Operation Count | 25,000 |
  | Warmup Ops | 2,500 |
  | Thread Count | 16 |
  | Time Compression Ratio | 0.001 |
  | Database | Apache AGE (`AgeInteractiveDb`) |
  | Endpoint | Azure West US 3 (HorizonDB) |
  | Disabled Queries | Q13, Q14 |

  ---

  ## Overall Results

  | Metric | Value |
  |---|---|
  | Total Operations | 25,084 |
  | Total Duration | 02:48.846 (~2 min 49 sec) |
  | Throughput | **148.56 ops/sec** |
  | Start Time (UTC) | 2026-05-15 16:11:24 |
  | Finish Time (UTC) | 2026-05-15 16:14:13 |
  | Schedule Audit | **FAILED** |

  ---

  ## Query Performance (Latency in ms)

  ### Complex Reads (Q1–Q12)

  | Query | Count | Mean | p50 | p90 | p95 | p99 | Max |
  |---|---|---|---|---|---|---|---|
  | Q1 | 232 | 795 | 711 | 1,279 | 1,564 | 2,174 | 2,522 |
  | Q2 | 163 | **175** | 2 | 541 | 844 | 1,313 | 2,571 |
  | Q3 | 65 | 612 | 485 | 1,001 | 1,249 | 1,594 | 1,678 |
  | Q4 | 167 | 339 | 209 | 751 | 1,022 | 1,437 | 2,055 |
  | Q5 | 92 | 352 | 292 | 688 | 767 | 1,416 | 1,846 |
  | Q6 | 26 | 467 | 251 | 910 | 1,553 | 1,847 | 1,847 |
  | Q7 | 112 | 191 | 34 | 528 | 825 | 1,346 | 2,001 |
  | Q8 | 402 | 197 | 8 | 611 | 910 | 1,378 | 2,372 |
  | Q9 | 21 | 482 | 351 | 774 | 1,236 | 1,251 | 1,251 |
  | Q10 | 172 | **1,091** | 994 | 1,490 | 1,643 | 2,210 | 2,635 |
  | Q11 | 317 | 583 | 442 | 931 | 1,103 | 2,539 | **5,263** |
  | Q12 | 137 | 606 | 477 | 980 | 1,194 | 2,006 | 3,525 |

  ### Short Reads (SQ1–SQ7)

  | Query | Count | Mean | p50 | p90 | p95 | p99 | Max |
  |---|---|---|---|---|---|---|---|
  | SQ1 PersonProfile | 2,370 | 35 | 1 | 40 | 241 | 670 | 2,424 |
  | SQ2 PersonPosts | 2,370 | 38 | 8 | 42 | 107 | 727 | 2,822 |
  | SQ3 PersonFriends | 2,370 | 39 | 3 | 26 | 228 | 856 | 2,515 |
  | SQ4 MessageContent | 2,360 | 74 | 1 | 244 | 474 | 1,041 | 3,476 |
  | SQ5 MessageCreator | 2,360 | 24 | 2 | 2 | 99 | 650 | 1,773 |
  | SQ6 MessageForum | 2,360 | 23 | 2 | 3 | 53 | 638 | 2,057 |
  | SQ7 MessageReplies | 2,360 | 21 | 5 | 7 | 43 | 451 | 2,208 |

  ### Updates (U1–U8)

  | Update | Count | Mean | p50 | p90 | p95 | p99 | Max |
  |---|---|---|---|---|---|---|---|
  | U1 AddPerson | 2 | 306 | 189 | 422 | 422 | 422 | 422 |
  | U2 AddPostLike | 952 | 271 | 214 | 490 | 732 | 1,592 | 2,542 |
  | U3 AddCommentLike | 1,182 | **540** | 500 | 919 | 1,101 | 1,807 | 3,091 |
  | U4 AddForum | 30 | 187 | 24 | 528 | 916 | 1,098 | 1,098 |
  | U5 AddForumMembership | 2,980 | **101** | 15 | 299 | 554 | 1,261 | 3,190 |
  | U6 AddPost | 385 | 306 | 26 | 940 | 1,403 | 2,074 | 2,642 |
  | U7 AddComment | 973 | **1,022** | 122 | 3,018 | 4,690 | 7,880 | **10,603** |
  | U8 AddFriendship | 124 | 132 | 11 | 462 | 663 | 1,043 | 1,773 |

  ---

  ## Schedule Audit — FAILED

  **8,435 late operations** against a tolerance limit of **1,250**.

  | Operation | Late Count |
  |---|---|
  | LdbcUpdate5AddForumMembership | 2,949 |
  | LdbcUpdate3AddCommentLike | 1,168 |
  | LdbcUpdate7AddComment | 963 |
  | LdbcUpdate2AddPostLike | 940 |
  | ... | ... |

  ---

  ## Key Issues

  1. **Schedule Audit FAILED** — 8,435 late ops vs. 1,250 tolerance across virtually all types.
  2. **U7 (AddComment) worst performer** — Mean 1,022 ms, max 10,603 ms, strongly bimodal (p50: 122 ms, p90: 3,018 ms).
  3. **Q10 slowest complex read** — Mean 1,091 ms, consistently high across all percentiles.
  4. **Q11 extreme outlier** — Max 5,263 ms, p99 at 2,539 ms.
  5. **Short reads degraded vs. Run 1** — SQ4 mean jumped from ~6 ms to 74 ms; heavy tail latency at p95.
  6. **U5 near-100% late rate** — 2,949 of 2,980 executions were late, the largest contributor to schedule slippage.