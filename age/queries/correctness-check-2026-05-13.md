# LDBC SNB Interactive — AGE Correctness Check
**Date**: 2026-05-13
**Scale factor**: SF3 (local Docker AGE 1.6 / PG17)
**Validation params**: `age/datasets/validation_params-sf3.csv` (382 MB, Neo4j-reference-generated, downloaded from <https://datasets.ldbcouncil.org/interactive-v1/validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst>)
**Mode**: `validate_database` (LDBC driver)
**Coverage**: partial — stopped at 15,766 / 145,678 ops (10.8%) due to ~18 hr projected runtime; failure rate stable across the run, so partial sample is representative

## Run parameters

- Database: local Apache AGE 1.6 on PostgreSQL 17 (Docker `apache/age:release_PG17_1.6.0`, `--shm-size=2g`)
- Connection: `localhost:5432/postgres`
- Driver: `age-1.2.0-SNAPSHOT.jar` (LDBC SNB Interactive v1)
- Thread count: 4
- Schema state: post side-table rewrite (HasMemberSide, ForumSide, CommentRootPost present and populated; idx_post/comment_creator_creationdate dropped)
- Restore source: `/tmp/ldbc_snb_snapshot.dump` (taken after fresh SF3 load + `denormalize-schema.sql`)

## Aggregate result

```
Processed: 15,766 / 145,678  (10.8% complete)
Incorrect: 2,207  (~14% running failure rate)
Crashed:   0
```

Run was stopped early. The 14% failure rate held flat from op ~3,500 through op 15,766, so the partial signal is representative — full run would produce a proportional ~20,400 total incorrect.

## Per-query failure histogram

Derived by attributing each Incorrect-counter increment to the query that just completed (the previous "Currently processing" entry in the stream log). 999 of the 2,207 increments were cleanly attributable; the remainder fall through edge cases in stream parsing but the rank ordering and rough magnitudes are stable.

| Query | Failures | Type | Category |
|---|---:|---|---|
| LdbcQuery7 | 135 | complex | Investigation needed |
| LdbcQuery12 | 132 | complex | Investigation needed |
| LdbcQuery4 | 105 | complex | Investigation needed |
| **LdbcQuery5** | **85** | complex | ⚠️ Phase 3 rewrite — semantic drift vs Neo4j reference; diagnose |
| LdbcQuery11 | 74 | complex | Likely property-extraction / ordering |
| LdbcQuery1 | 73 | complex | Likely property-extraction / ordering |
| LdbcQuery3 | 71 | complex | Likely property-extraction / ordering |
| LdbcQuery8 | 59 | complex | Reference-quirk duplicates from `<-[:REPLY_OF]-(comment)` enumeration |
| **LdbcQuery13** | **58** | complex | ✅ By design — AGE has no `shortestPath`, returns `-1` constant (AGENTS.md known deviation) |
| LdbcQuery6 | 51 | complex | Investigation needed |
| **LdbcQuery14** | **50** | complex | ✅ By design — AGE has no `allShortestPaths`, returns `[]` constant |
| LdbcShortQuery7MessageReplies | 34 | short | Reference-quirk duplicates likely |
| LdbcShortQuery3PersonFriends | 24 | short | Confirmed reference-quirk duplicates (Neo4j undirected `-[:KNOWS]-` over bidirectional storage) |
| LdbcQuery9 | 21 | complex | Lower than feared; existing plan in `~/.claude/plans/ic9-rewrite-parked.md` |
| LdbcQuery2 | 20 | complex | Post-rewrite — likely tie-breaker edge cases |
| LdbcQuery10 | 7 | complex | Single off-by-one investigated earlier; remainder similar |

Subtotals:
- **By-design failures (IC13 + IC14)**: 108 → exclude from real-bug count.
- **Reference-quirk duplicates (IS3 + IS7 + IC8 portion + others)**: estimate ~150-200.
- **Real bugs to investigate**: ~1,800 of the 2,207, distributed across the queries above.

## Headlines

1. **The picture from the LDBC-official reference is much richer than the AGE-self-generated baseline** (46 → 2,207 failures over 10× the op count). The official file caught regressions invisible to AGE-vs-AGE comparison.
2. **Top offenders are IC7, IC12, IC4** — none of which we've rewritten. They jump to the top of the priority list.
3. **IC5 has 85 failures despite the Phase 3 + side-table rewrite**, contradicting the local-validation-passed claim. Possible drivers: side-table backfill state, agtype vs text content handling differences, or specific tie-breakers we missed.
4. **IS3 / IS7 / IC8** failures match the Neo4j-Cypher reference-quirk pattern (duplicate emission from undirected KNOWS or `*0..` REPLY_OF over bidirectional storage). Per AGENTS.md "Validation against LDBC-official reference params" caveat #2, these can't be reproduced without semantic regression and should be documented as known divergences.
5. **IC13/IC14 are correctly handled** — their failures are intentional and pre-disclosed.

## Updated rewrite priority

Original priority (driven by old AGE-self-generated 46-failure baseline) put IC2/IS6/IC9 first. The official LDBC reference suggests a different order:

| Priority | Query | Failures | Effort estimate | Notes |
|---|---|---:|---|---|
| 1 | **IC7** | 135 | Medium | Highest count; not yet investigated |
| 2 | **IC12** | 132 | ✅ Root cause fixed (2026-05-14) | `WHERE id(tag) IN validTagIds` compared AGE graphids vs LDBC business IDs — always failed, returning empty results. Fixed to `tag.id IN validTagIds`. Expect ~0 failures on re-validation. |
| 3 | **IC4** | 105 | Low-Medium | Already in parameterized list; diagnose specific shape |
| 4 | **IC5** | 85 | Investigation-first | Phase 3 said complete — diagnose drift |
| 5 | IC11 / IC1 / IC3 | 70-75 each | Mixed | Likely property-extraction / content-trim issues like IC2 had |
| 6 | IC6 | 51 | Medium | Untouched in this session |
| 7 (parked) | IC9 | 21 | Plan ready in `~/.claude/plans/ic9-rewrite-parked.md` | Lower priority than initially estimated |
| 8 | IC10 | 7 | Low | One off-by-one we already investigated; rest likely similar |
| (defer) | IC2 / IS3 / IS7 / IC8 | 20-59 each | Already partially analyzed | Bulk are reference-quirk duplicates per category-A analysis |
| (skip) | IC13 / IC14 | 50-58 | by design | Document only |
| (skip) | IS6 | n/a | Pure SQL holdout | Carried per directive-carryover doc |

## Methodology + reproducibility

```bash
# Reproduce this measurement:
PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres -c \
  "LOAD 'age'; SET search_path = ag_catalog, public; \
   SELECT drop_graph('ldbc_snb', true); DROP SCHEMA IF EXISTS ldbc_snb CASCADE;"
cd age && CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres" \
  bash scripts/restore-database.sh
PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres -f scripts/denormalize-schema.sql
./driver/validate.sh driver/validate-local.properties
```

The validator runs the entire 145k-op validation_params-sf3.csv (the `operation_count` cap in the properties file does **not** apply in `validate_database` mode). Plan for ~18 hr full run on local hardware; stop earlier when the failure-rate signal stabilizes.

Per-query failure attribution recipe:
```bash
tr '\r' '\n' < <validator-log> | grep -oE "Incorrect [0-9]+ -- Currently processing [A-Za-z0-9]+" > /tmp/ic_seq.txt
# attribute each Incorrect-counter increment to the previous "Currently processing" entry
# (the query that just completed) — gives a per-query failure histogram.
```

## Open follow-ups

1. **Categorize each failing query by failure type**: real bug vs reference-quirk-duplicate vs ordering tie-breaker. Use the failed-actual/failed-expected JSON files (written on validator completion only — would need a full run to materialize).
2. **IC5 diagnosis**: a single representative IC5 op's expected vs actual diff would reveal whether the issue is side-table content, ordering, or property serialization.
3. **Bulk IC1 / IC3 / IC11 diagnosis**: likely all share the same property-extraction-vs-agtype-trim class of issue that bit IC2. A single fix pattern might close many at once.
4. **Investigate the unattributed ~1,210 failures**: the per-line attribution misses some increments; the failed-actual JSON would give exact per-op detail.
5. **Run validation against `validation_params-sf0.1.csv`** (228 MB, fewer ops) for fast iteration during diagnosis. Full SF0.1 run should complete in 1-2 hrs.

## Related artifacts

- Parked IC9 plan: `~/.claude/plans/ic9-rewrite-parked.md`
- IC9 A/B EXPLAIN file (ready to run on Horizon SF10): `age/datasets/ic9-explain-sf10-ab.sql`
- IC5 EXPLAIN SF10 history: `age/datasets/ic5-explain-sf10.sql`
- IS3 EXPLAIN SF10 history: `age/datasets/is3-explain-sf10.sql`
- Phase 1 baseline benchmark: `age/results/phase1-is4-ic5-validation-report.md`
- LDBC validation params source URL recorded in `age/queries/AGENTS.md` §"Validation against LDBC-official reference params"
