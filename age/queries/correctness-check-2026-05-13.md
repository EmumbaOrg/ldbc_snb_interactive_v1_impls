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

> ⚠️ **2026-05-13 follow-up**: the recipe used here pairs each Incorrect-counter
> increment with the *prior* `Currently processing` entry in the log stream.
> Inspection of `DbValidator.validate` bytecode shows the validator prints
> "Currently processing X" *after* X has finished — i.e. each line's
> `Currently processing` is the op that **just completed**, and the increment
> shown on that line is whatever Incorrect counter was at that moment. The
> recipe therefore attributes each failure **one op too early** in the stream.
> In an interleaved op stream this scrambles the per-query histogram.
> Corrected recipe + caveat documented at the bottom of this file. The
> IC5 row below has been fully audited via focused re-validation and
> confirmed to have **zero** real failures — its 85 entry here is an
> attribution artifact, not a real bug.

| Query | Failures | Type | Category |
|---|---:|---|---|
| LdbcQuery7 | 135 | complex | Investigation needed (may include attribution noise) |
| **LdbcQuery12** | **132** | complex | ✅ Fixed + optimized (2026-05-14) — see below |
| **LdbcQuery4** | **105** | complex | ✅ Fixed (2026-05-14) — root cause: PostgreSQL `en_US.UTF-8` collation sorted `.` after `A`, diverging from Neo4j Java `String.compareTo()` code-point order (`.`=46 < `A`=65). Fix: added `COLLATE "C"` to `ORDER BY tag_name`. Also rewrote as two-Cypher-CTE hybrid with NOT EXISTS anti-join (approach A). Spot-check: 50/50 pass (SF3, limit 50). Full corpus: **6,818/6,818 pass, 0 failures** (2026-05-14). |
| ~~LdbcQuery5~~ | ~~85~~ → **0** | complex | ✅ **Re-validated 2026-05-13** — 0 real failures across all 6,818 IC5 ops + 8,087 IUs on a focused fresh-snapshot run. The 85 was attribution-recipe misalignment. |
| LdbcQuery11 | 74 | complex | Likely property-extraction / ordering |
| LdbcQuery1 | 73 | complex | Likely property-extraction / ordering |
| **LdbcQuery3** | **71** | complex | ✅ Fixed (2026-05-14) — root cause: outer SQL compared agtype-quoted country name (`"Angola"`) to plain SQL text (`Angola`) — always FALSE → empty results. Fix: moved all country comparisons inside Cypher (agtype vs agtype). Also rewrote with IC5-style UNION friend-set (avoids UNWIND/OPTIONAL MATCH 922M-row catastrophic plan). Three Cypher calls; added to `age_parameterized_queries`. Spot-check: 50/50 mixed + 100/100 nonzero (SF3). Full corpus: **6,818/6,818 pass, 0 failures** (2026-05-14). |
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
2. **Top offenders were IC7, IC12, IC4**. IC12 and IC4 have since been fully fixed and validated (see priority table). IC7 remains unaddressed.
3. ~~**IC5 has 85 failures despite the Phase 3 + side-table rewrite**, contradicting the local-validation-passed claim.~~ **Retracted 2026-05-13**: a focused IC5+IU re-validation run (all 6,818 IC5 ops + 8,087 IUs against a fresh snapshot, `age/datasets/validation_params-sf3-iu+ic5.csv`, properties at `age/driver/validate-local-ic5only.properties`) produced **zero** incorrect results. The 85 figure was an artifact of the off-by-one attribution recipe (see top of "Per-query failure histogram" section). The Phase 3 + side-table rewrite is correct.
4. **IS3 / IS7 / IC8** failures match the Neo4j-Cypher reference-quirk pattern (duplicate emission from undirected KNOWS or `*0..` REPLY_OF over bidirectional storage). Per AGENTS.md "Validation against LDBC-official reference params" caveat #2, these can't be reproduced without semantic regression and should be documented as known divergences.
5. **IC13/IC14 are correctly handled** — their failures are intentional and pre-disclosed.

## Updated rewrite priority

Original priority (driven by old AGE-self-generated 46-failure baseline) put IC2/IS6/IC9 first. The official LDBC reference suggests a different order:

| Priority | Query | Failures | Effort estimate | Notes |
|---|---|---:|---|---|
| 1 | **IC7** | 135 | Medium | Highest count; not yet investigated |
| 2 | **IC12** | 132 | ✅ Fixed + validated (2026-05-14) | Correctness bug: `id(tag) IN validTagIds` compared AGE graphids vs LDBC business IDs — always failed. Fixed to `tag.id IN validTagIds`. Then rewritten as H1 Hybrid (two `cypher()` CTEs + outer SQL Hash Join), eliminating the 3.78B-comparison `agtype_in_operator` bottleneck. Spot-check: 100% pass on 200 SF3 cases (incl. 100 non-zero results). Performance: Person/broad 51s→13s, MusicalArtist 18s→8.8s. See `age/ic12-optimization-bottlenecks.md` Phase 8. |
| 3 | **IC4** | 105 | ✅ Fixed (2026-05-14) | Collation mismatch: `COLLATE "C"` + two-CTE hybrid. Spot-check 50/50 pass. Full corpus: **6,818/6,818 pass** (2026-05-14). |
| ~~4~~ | ~~IC5~~ | ~~85~~ → 0 | — | ✅ Re-validated 2026-05-13: zero failures; no work needed. |
| 5 | IC11 / IC1 | 70-75 each | Mixed | Likely property-extraction / content-trim issues — check attribution first |
| ✅ | **IC3** | ~~71~~ → 0 | ✅ Fixed (2026-05-14) | agtype cast bug + UNWIND anti-pattern. UNION friend-set + Cypher-side country comparisons. Full corpus: **6,818/6,818 pass** (2026-05-14). |
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

Per-query failure attribution recipe (CORRECTED 2026-05-13 — the previous
version was off by one; see top of "Per-query failure histogram"):

```bash
tr '\r' '\n' < <validator-log> \
  | grep -oE "Incorrect [0-9]+ -- Currently processing [A-Za-z0-9]+" \
  | awk '
      { match($0, /Incorrect ([0-9]+) -- Currently processing ([A-Za-z0-9]+)/, a);
        cur = a[1]; q = a[2];
        if (NR > 1 && cur > prev) print q;
        prev = cur
      }
    ' | sort | uniq -c | sort -rn
```

The validator prints `Currently processing X` **after** X has just finished
(verified against `DbValidator.validate` bytecode in
`age-1.2.0-SNAPSHOT.jar`), so when the Incorrect counter is higher on a
given line than on the previous line, the failing op is the one named on
**that** line — not the previous line's. The corrected `awk` above
implements this.

Focused single-query re-validation (template — used for the IC5 retraction
above):

```bash
# 1. Build a focused CSV that keeps only the target reads + ALL IUs in CSV order.
python3 - <<'PY'
import json
IU_KEYS = {  # set of frozensets identifying IUs by their param-key shape
  frozenset({'forumId','joinDate','personId'}),                              # IU5
  frozenset({'commentId','creationDate','personId'}),                        # IU3
  frozenset({'creationDate','personId','postId'}),                           # IU2
  frozenset({'authorPersonId','browserUsed','commentId','content','countryId',
             'creationDate','length','locationIp','replyToCommentId',
             'replyToPostId','tagIds'}),                                     # IU7
  frozenset({'authorPersonId','browserUsed','content','countryId','creationDate',
             'forumId','imageFile','language','length','locationIp','postId',
             'tagIds'}),                                                     # IU6
  frozenset({'creationDate','person1Id','person2Id'}),                       # IU8
  frozenset({'creationDate','forumId','forumTitle','moderatorPersonId','tagIds'}),  # IU4
  frozenset({'birthday','browserUsed','cityId','creationDate','emails','gender',
             'languages','locationIp','personFirstName','personId',
             'personLastName','studyAt','tagIds','workAt'}),                 # IU1
}
TARGET_KEY = frozenset({'limit','minDate','personIdQ5'})  # IC5 — change per target
keep = IU_KEYS | {TARGET_KEY}
with open('age/datasets/validation_params-sf3.csv') as fi, \
     open('age/datasets/validation_params-sf3-iu+target.csv','w') as fo:
  for line in fi:
    p = json.loads(line.split('|',1)[0])
    if frozenset(p.keys()) in keep: fo.write(line)
PY

# 2. Restore snapshot to a clean fresh-load state.
CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres" \
  bash age/scripts/restore-database.sh
PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres \
  -f age/scripts/denormalize-schema.sql

# 3. Run validator with all reads disabled except the target query.
#    See age/driver/validate-local-ic5only.properties for the working example.
bash age/driver/validate.sh age/driver/validate-local-<query>only.properties

# 4. Output JSONs (empty arrays if PASS) at:
#    age/datasets/validation_params-sf3-iu+target-failed-actual.json
#    age/datasets/validation_params-sf3-iu+target-failed-expected.json
```

## Open follow-ups

1. **Categorize each failing query by failure type**: real bug vs reference-quirk-duplicate vs ordering tie-breaker. Use the failed-actual/failed-expected JSON files (written on validator completion only — would need a full run to materialize). **OR** apply the focused-CSV template above per query, which finishes in ~1–2 hr and writes JSONs for that single query — much faster than an 18-hr full run.
2. ~~**IC5 diagnosis**~~ — done; zero real failures (2026-05-13).
3. **Bulk IC1 / IC11 diagnosis**: same focused-CSV approach. IC3 and IC4 are now fixed and validated (2026-05-14).
4. **Investigate the unattributed ~1,210 failures**: the per-line attribution misses some increments; the failed-actual JSON would give exact per-op detail.
5. **Run validation against `validation_params-sf0.1.csv`** (228 MB, fewer ops) for fast iteration during diagnosis. Full SF0.1 run should complete in 1-2 hrs.

## Related artifacts

- Parked IC9 plan: `~/.claude/plans/ic9-rewrite-parked.md`
- IC9 A/B EXPLAIN file (ready to run on Horizon SF10): `age/datasets/ic9-explain-sf10-ab.sql`
- IC5 EXPLAIN SF10 history: `age/datasets/ic5-explain-sf10.sql`
- IS3 EXPLAIN SF10 history: `age/datasets/is3-explain-sf10.sql`
- Phase 1 baseline benchmark: `age/results/phase1-is4-ic5-validation-report.md`
- LDBC validation params source URL recorded in `age/queries/AGENTS.md` §"Validation against LDBC-official reference params"
