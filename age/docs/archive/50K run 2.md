# LDBC SNB Interactive Benchmark — Apache AGE
## Run 3 · Scale Factor 10 · 50k Operations · 2026-05-14

---

## Configuration

| Parameter | Value |
|-----------|-------|
| Database | Apache AGE (`AgeInteractiveDb`) |
| Workload | LDBC SNB Interactive v1 |
| Scale Factor | 10 (SF10) |
| Operation Count | 50,000 |
| Warmup Operations | 5,000 |
| Thread Count | 16 |
| Connection Pool Size | 16 |
| Time Compression Ratio | 0.001 |
| Endpoint | `horizondb-graph-benchmarking.*.westus3.horizondb.azure.com` |
| Graph Name | `ldbc_snb` |

Queries Q13 and Q14 were **disabled** in this run.

---

## Overall Results

| Metric | Warmup | Benchmark |
|--------|--------|-----------|
| Total Operations | 5,140 | 49,956 |
| Total Duration | 43,489 ms (~43.5 s) | 333,500 ms (~5.6 min) |
| **Throughput** | **118.19 ops/sec** | **149.79 ops/sec** |

---

## Scheduling Delay Analysis

The benchmark tracks how late each operation starts relative to its scheduled time. A delay > 1,000 ms indicates the system cannot keep pace with the planned schedule.

| Metric | Value |
|--------|-------|
| Excessive Delay Threshold | 1,000 ms |
| Operations Exceeding Threshold | **16,766 / 49,956 (33.6%)** |
| Min Delay | 0 ms |
| Max Delay | 327,924 ms (~5.5 min) |
| Mean Delay | 47,949 ms (~48 s) |

High excessive-delay counts indicate significant scheduling backpressure, primarily in update operations and complex long reads.

---

## Long Read Query Performance (Q1–Q12)

All times in milliseconds (ms).

| Query | Count | Mean | P50 | P75 | P90 | P95 | P99 | Max |
|-------|------:|-----:|----:|----:|----:|----:|----:|----:|
| Q1  — Friend of Friend w/ Name | 459 | 578 | 401 | 655 | 1,113 | 1,450 | 2,225 | 3,216 |
| Q2  — Recent Messages of Friends | 323 | 270 | 3 | 422 | 814 | 1,401 | 2,034 | 2,250 |
| Q3  — Friends Common Interests | 130 | 773 | 534 | 977 | 1,299 | 1,775 | 2,277 | 3,179 |
| Q4  — New Topics | 332 | 448 | 234 | 550 | 1,018 | 1,463 | 2,254 | 3,700 |
| Q5  — New Groups | 182 | 465 | 300 | 583 | 977 | 1,301 | 2,392 | 2,805 |
| Q6  — Tag Co-occurrence | 50 | 552 | 342 | 722 | 1,230 | 1,627 | 2,509 | 2,509 |
| Q7  — Recent Likers | 221 | 305 | 69 | 439 | 921 | 1,202 | 1,857 | 2,483 |
| Q8  — Recent Replies | 797 | 254 | 8 | 355 | 772 | 1,191 | 2,045 | 3,869 |
| Q9  — Recent Forum Posts | 42 | 515 | 353 | 522 | 893 | 1,189 | 2,199 | 2,199 |
| Q10 — Friend Recruitment | 342 | 1,151 | 991 | 1,213 | 1,819 | 2,076 | 2,874 | 3,027 |
| Q11 — Job Referral | 629 | 600 | 437 | 664 | 1,123 | 1,489 | 2,193 | 4,420 |
| Q12 — Expert Search | 272 | 904 | 458 | 676 | 1,396 | 1,735 | 2,728 | **68,372** :warning: |

> **Q12 Note:** The maximum of 68,372 ms is a significant outlier (99.9th pct matches, suggesting a single extreme event). Q10 has the highest mean at 1,151 ms.

---

## Short Read Query Performance (SQ1–SQ7)

Short reads are lightweight lookups. All times in ms.

| Query | Count | Mean | P50 | P90 | P95 | P99 | Max |
|-------|------:|-----:|----:|----:|----:|----:|----:|
| SQ1 — Person Profile | 4,738 | 25.8 | 1 | 2 | 44 | 781 | 2,036 |
| SQ2 — Person Posts | 4,738 | 24.1 | 7 | 25 | 58 | 438 | 2,258 |
| SQ3 — Person Friends | 4,738 | 22.9 | 2 | 10 | 18 | 697 | 3,618 |
| SQ4 — Message Content | 4,721 | 61.4 | 1 | 63 | 435 | 1,341 | 3,283 |
| SQ5 — Message Creator | 4,721 | 17.5 | 2 | 2 | 3 | 505 | 4,216 |
| SQ6 — Message Forum | 4,721 | 10.7 | 2 | 3 | 3 | 306 | 2,814 |
| SQ7 — Message Replies | 4,721 | 13.9 | 5 | 7 | 7 | 343 | 2,455 |

Short reads are generally fast (median ≤ 7 ms for SQ2–SQ7), but P99 spikes into the hundreds of ms, likely due to scheduling backpressure and connection-pool contention.

---

## Update Operation Performance (U1–U8)

| Update | Count | Mean | P50 | P90 | P95 | P99 | Max |
|--------|------:|-----:|----:|----:|----:|----:|----:|
| U1 — Add Person | 4 | 202 | 80 | 437 | 437 | 437 | 437 |
| U2 — Add Post Like | 1,879 | 257 | 195 | 453 | 775 | 1,703 | 3,647 |
| U3 — Add Comment Like | 2,368 | 542 | 515 | 904 | 1,102 | 1,842 | 3,074 |
| U4 — Add Forum | 65 | 206 | 23 | 863 | 911 | 1,003 | 1,012 |
| U5 — Add Forum Membership | 5,809 | 91 | 14 | 265 | 577 | 1,338 | 3,854 |
| U6 — Add Post | 790 | 323 | 24 | 1,043 | 1,387 | 2,471 | 5,129 |
| U7 — Add Comment | 1,924 | **1,036** | 68 | 2,893 | 4,844 | 8,553 | **11,851** :warning: |
| U8 — Add Friendship | 240 | 128 | 10 | 431 | 780 | 1,499 | 3,341 |

> **U7 Note:** Add Comment has the worst update performance — mean of 1,036 ms and a max of nearly 12 seconds. The bimodal P50/P90 split (68 ms vs 2,893 ms) suggests two distinct execution paths.

---

## Key Observations

1. **Throughput:** 149.79 ops/sec in the benchmark phase, up from 118.19 ops/sec during warmup — indicates effective JIT/cache warm-up.

2. **Scheduling pressure is high:** 33.6% of operations experienced delays > 1 second, with a mean delay of ~48 seconds. The system is consistently behind its scheduled operation times.

3. **Update U7 (Add Comment) is the bottleneck:** Highest mean latency (1,036 ms) and highest max (11,851 ms) among updates. Excessive delay count is second highest (1,913).

4. **Q10 (Friend Recruitment) is the slowest long read:** Mean of 1,151 ms with a tight latency distribution (P25–P99: 894–2,874 ms), indicating consistently slow graph traversal.

5. **Q12 (Expert Search) has an extreme outlier:** A single query took 68,372 ms (~68 s), far beyond the P99.9 of any other query. Warrants investigation.

6. **Short reads are well-optimized:** Medians of 1–7 ms for SQ1–SQ7. Tail latencies are driven by system-wide contention, not query complexity.

7. **U5 (Forum Membership) dominates update volume:** 5,809 executions — the most frequent update by a large margin. Despite high volume, mean is only 91 ms.