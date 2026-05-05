# Plan: Use AgeFreighter as the production loader

**Audience**: an AI agent (Claude Code or similar) tasked with replacing `scripts/load-production-data.py` with an `agefreighter`-based loader, while preserving the data-correctness invariants required by the LDBC SNB Interactive workload.

**Scope**: SF0.1 through SF1000. Anything below SF0.1 uses the dev `load-test-data.py` flow.

---

## 1. Background

### What works today
- `scripts/load-production-data.py` is a custom Python loader that:
  1. Drops the `ldbc_snb` graph in AGE.
  2. For each vertex label, reads the corresponding CSV in `converted/sf{N}/vertices/` and runs `COPY {graph}.{label} FROM STDIN (FORMAT CSV)` with agtype-formatted properties.
  3. Creates GIN indexes on vertex `properties`.
  4. For each edge label, reads CSVs in `converted/sf{N}/edges/`, resolves `start_id`/`end_id` against the per-label id maps, and `COPY`s.
- After loading, `scripts/create-indexes.sql` adds B-tree indexes on extracted properties, `scripts/vacuum-analyze.sh` updates planner stats, and `scripts/snapshot-database.sh` takes a `pg_dump -Fc` snapshot.
- LDBC validation against the resulting DB **passes for all queries except IC13/IC14** (Apache AGE 1.6.0 has no `shortestPath()` / `allShortestPaths()`; both are documented stubs in `queries/interactive-complex-13.sql` and `queries/interactive-complex-14.sql`).

### Why we want to migrate to agefreighter
- `agefreighter` is the canonical loader Microsoft ships for AGE-on-PostgreSQL. The `GraphBenchmarking` SF3 bootstrap doc (`SF3 BENCHMARK BOOTSTRAP.md` Phase 13) already uses it.
- Aligning with upstream tooling reduces our maintenance burden, gets dependency updates for free, and removes a "why does this repo have its own loader?" question.
- agefreighter has battle-tested chunking, connection pooling, and concurrent COPY pipelines; our custom loader is single-threaded.

### Why we cannot use agefreighter as-is
There is one concrete bug that blocks us. It is well-localized.

`agefreighter --source-type csv` flow:
1. `agefreighter/main.py` `handle_load()` dispatches to `CSVExporter` (`agefreighter/csvexporter.py`).
2. `CSVExporter.export_nodes()` reads each source CSV, builds `[{id, properties}, ...]`, and calls `self.write_csv(label, "v", all_data)` (inherited from `AgeFreighter`).
3. `AgeFreighter.write_csv()` (`agefreighter/agefreighter.py:524–610`) emits an *intermediate* CSV with one row per vertex/edge whose final column is the agtype properties literal.
4. `AgeFreighter._copy()` (`agefreighter/agefreighter.py:293`) runs `COPY {graph}.{label} FROM STDIN (FORMAT CSV)` against the intermediate CSV.

The breakage is the nested closure `format_kv` inside `write_csv` at `agefreighter/agefreighter.py:537–545`:

```python
def format_kv(key: str, value: Any) -> str:
    safe_value = (
        str(value)
        .replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace('\\\\"', '"')
        .replace('"', '\\""')
    )
    return f'""{key}"": ""{safe_value}""'   # <-- everything is quoted as a string
```

Every property is emitted as an agtype string, regardless of whether the source value is numeric. So `id=933` is stored as `{"id": "933"}` (string) instead of `{"id": 933}` (integer). All our LDBC interactive queries use bare integer literals: `MATCH (p:Person {id: $personId})` compiles to `properties @> '{"id": 933}'::agtype`, which is type-strict — string `"933"` ≠ integer `933`. **Every MATCH on an `id` returns 0 rows.**

The same bug also affects `creationDate`, `birthday`, `length`, `classYear`, `workFrom`, `joinDate` — anywhere we use range filters or numeric arithmetic.

`agefreighter` v1.0.33 (the latest as of 2026-05-05) does not address this. Recent commits (`git log` in `~/repositories/agefreighter`) are all dependency updates and one ID-collision/perf fix; nothing touches `format_kv`.

#### Verification of the bug (one-line repro)
```bash
PGPASSWORD=postgres psql -h localhost -U postgres -d postgres \
  -c "LOAD 'age'; SET search_path = ag_catalog, public;
      SELECT * FROM cypher('ldbc_snb', \$\$ MATCH (p:Person {id: 933}) RETURN p.firstName \$\$) AS (name agtype);"
```
- Against an `agefreighter`-loaded DB: `0 rows`.
- Against a `load-production-data.py`-loaded DB: `"Mahinda"`.
- Workaround that the SF3 bootstrap doc uses: change to `id: '933'` (single-quoted string) — then it matches. But our queries can't be rewritten that way; LDBC params are passed as `Long` from the Java driver and substituted as bare integers.

---

## 2. Constraints

| # | Constraint | Source |
|---|---|---|
| C1 | All numeric LDBC properties must be stored as agtype integers, not strings. | LDBC interactive queries use bare-integer MATCH literals; AGE `@>` is type-strict. |
| C2 | Empty-string fields must be **omitted** from properties (not stored as `""`). | LDBC `coalesce(content, imageFile)` for image posts must return imageFile. Storing `""` makes coalesce return `""` because empty string is non-null in Cypher. |
| C3 | KNOWS edges must be loaded bidirectionally (both `a→b` and `b→a`). | Our queries use directed `(p)-[:KNOWS]->(friend)` and `(p)-[:KNOWS]->(:Person)-[:KNOWS]->(friend)`; this only matches Neo4j undirected `[:KNOWS]-` if both directions exist. |
| C4 | Property numeric set: `id`, `birthday`, `creationDate`, `length`, `classYear`, `workFrom`, `joinDate`. JSON columns: `email`, `speaks` (Person). | Established in `scripts/load-production-data.py` `NUMERIC_PROPS`. |
| C5 | The loader must scale to SF1000 (≈3B properties, ≈10B edges). | Customer requirement; `load-production-data.py` is single-threaded and will not finish in a reasonable time. |
| C6 | Must be reproducible against the `agefreighter_config.json` already produced by `~/repositories/GraphBenchmarking/ldbc_snb_benchmark/preprocess_ldbc.py`. | That preprocessor is the source of truth for all SF{N}; it produces both the converted CSVs and the agefreighter config. |

`agefreighter`'s `write_csv` already handles C2 correctly — line 570 `if props.get(h, "")` skips empty strings. Good.

`agefreighter`'s `preprocess_ldbc.py` already handles C3 — the converted KNOWS.csv has 28,146 rows for SF0.1 (= 14,073 friendships × 2). Good.

So **the only constraint agefreighter currently fails is C1**.

---

## 3. Solution options

### Option A — Subclass `CSVExporter` in a wrapper script *(recommended for now)*

Smallest blast radius. We override `write_csv` in a subclass and run our subclassed exporter from a thin Python wrapper. No fork, no install pain.

**Pros**
- Uses everything else from upstream agefreighter: COPY pipeline, label management, connection pool, CSV reading optimization, sequence reset, GIN indexes.
- One file in our repo (`scripts/load-with-agefreighter.py`).
- Easy to delete once Plan B lands upstream.

**Cons**
- Brittle to upstream API changes — if `write_csv`'s signature or call site changes, our subclass breaks.
- Mitigation: pin agefreighter version via `pip install 'agefreighter==1.0.33'` in the loader's bootstrap docs.
- We have to duplicate ~50 lines of `write_csv`'s body to override the closure, since `format_kv` is defined inline. (Acceptable — the duplicated code is mechanical.)

### Option B — Fork agefreighter and submit upstream PR *(do this in parallel, retire Option A when merged)*

Permanent fix. Modify `format_kv` to accept a `numeric_keys: set[str]` (or look it up on `self`), and add a `numeric_props` field to `agefreighter_config.json` so callers can declare it.

**Pros**
- Cleanest, helps every AGE user, removes our maintenance.

**Cons**
- PR review/merge timeline is out of our control. We must run from a fork install (`pip install -e ~/repositories/agefreighter-fork`) until merged.

### Option C — Post-load SQL fixup

Run `agefreighter` as-is (everything quoted), then `UPDATE` every label table to rewrite numeric properties as integers in the `agtype` JSON.

**Why we reject this:**
- At SF1000, every Comment/Post update touches a multi-KB row. Rewriting ~3B properties via single-row UPDATEs is not viable; bulk batched updates still rewrite the entire heap. Even if it worked, it doubles the load wall-clock.
- The `agtype` JSON has no clean SQL primitive for "change just this key's type"; we'd round-trip text → jsonb → text → agtype per row, which is fragile.

---

## 4. Recommended implementation: Plan A in detail

### 4.1 New files
1. `scripts/load-with-agefreighter.py` — the wrapper (full skeleton in §4.4 below).
2. `scripts/test-agefreighter-load.py` — verifier that diffs the agefreighter-loaded DB against a `load-production-data.py`-loaded reference at SF0.1.

### 4.2 Modified files
1. `README.md` — add a sibling section under "Production data (SF0.1+)" titled "Loader B: `load-with-agefreighter.py`" that documents:
   - Why this exists (C1, with link to upstream issue/PR once filed).
   - Install: `pip install 'agefreighter==1.0.33'` plus `psycopg[binary]`.
   - Run: command in §4.5 below.
   - Comparison: when to choose A vs B (B is faster at SF≥10; A has no Python dep on agefreighter and is easier to debug).
2. `requirements.txt` (create if absent) — pin `agefreighter==1.0.33` and `psycopg[binary]>=3.0`.

### 4.3 Constants the wrapper must expose

Pull these from `scripts/load-production-data.py` lines 37–40:
```python
NUMERIC_PROPS = frozenset({
    "id", "birthday", "creationDate", "length",
    "classYear", "workFrom", "joinDate",
})
```

Compound (JSON) properties — these must be passed through as agtype literals, not quoted:
```python
COMPOUND_PROPS = frozenset({"email", "speaks"})
```
(Detection: source value starts with `[` or `{` after `.strip()`.)

### 4.4 Skeleton: `scripts/load-with-agefreighter.py`

```python
#!/usr/bin/env python3
"""
agefreighter-based loader with correct numeric-property typing.

Subclasses CSVExporter to override write_csv so numeric properties
emit bare ints (not quoted strings). Required because Apache AGE
@> containment is type-strict and our queries use integer literals.

Drop-in replacement for `agefreighter --source-type csv`. Same CLI,
same agefreighter_config.json. Pin: agefreighter==1.0.33.

Usage:
    python3 scripts/load-with-agefreighter.py \
      --pg-con-str "host=... dbname=..." \
      --graphname ldbc_snb \
      --config converted/sf3/agefreighter_config.json \
      --progress
"""
import argparse
import asyncio
import logging
import os
import sys
import tempfile
from datetime import datetime
from typing import Any, Dict, List, Optional

import aiofiles
from agefreighter.csvexporter import CSVExporter

NUMERIC_PROPS = frozenset({
    "id", "birthday", "creationDate", "length",
    "classYear", "workFrom", "joinDate",
})

log = logging.getLogger("load-with-agefreighter")


class TypedCSVExporter(CSVExporter):
    """CSVExporter with correct typing for numeric and compound properties."""

    async def write_csv(
        self, label: str, kind: str, data: List[Dict[str, Any]]
    ) -> str:
        """
        Mirror of AgeFreighter.write_csv (agefreighter.py L524-L610) with one
        change: format_kv emits bare ints for NUMERIC_PROPS and unquoted
        agtype literals for compound (JSON) values. Empty values are skipped
        (same as upstream).

        IMPORTANT: keep this method body identical to upstream except for
        format_kv. When upgrading agefreighter, re-diff this against
        upstream's write_csv.
        """
        if not data:
            log.info("No data to write for '%s'.", label)
            return ""

        def format_kv(key: str, value: Any) -> str:
            # NEW: numeric props -> bare int
            if key in NUMERIC_PROPS:
                try:
                    return f'""{key}"": {int(float(value))}'
                except (TypeError, ValueError):
                    pass  # fall through to string handling
            # NEW: compound props (JSON arrays/objects) -> raw agtype literal
            sval = str(value).strip()
            if sval.startswith("[") or sval.startswith("{"):
                # Need to escape inner double-quotes for the outer CSV layer.
                escaped = sval.replace('"', '\\""')
                return f'""{key}"": {escaped}'
            # original behavior for plain strings
            safe_value = (
                str(value)
                .replace("\\", "\\\\")
                .replace("\t", "\\t")
                .replace('\\\\"', '"')
                .replace('"', '\\""')
            )
            return f'""{key}"": ""{safe_value}""'

        # ----- everything below is copied verbatim from upstream
        # AgeFreighter.write_csv (agefreighter.py L547-L610) -----
        normal_file_path = (
            os.path.join(self.output_dir, f"{label.lower()}.csv")
            if self.output_dir
            else tempfile.NamedTemporaryFile(delete=False).name
        )
        tab_file_path: Optional[str] = None
        tab_file = None
        headers = self.extract_unique_keys(data)
        BATCH_SIZE = 10000

        try:
            async with aiofiles.open(
                normal_file_path, "w", encoding="utf-8", newline=""
            ) as normal_f:
                normal_lines: List[str] = []
                tab_lines: List[str] = []
                for row in data:
                    props = row.get("properties", {})
                    formatted_parts = [
                        format_kv(h, props.get(h, ""))
                        for h in headers
                        if props.get(h, "")  # skip empty (matches upstream + C2)
                    ]
                    line = ", ".join(formatted_parts)
                    if kind == "e":
                        csv_line = f'{row["id"]},{row["start_id"]},{row["end_id"]},"{{{line}}}"\n'
                    elif kind == "v":
                        csv_line = f'{row["id"]},"{{{line}}}"\n'
                    else:
                        raise ValueError(f"Unsupported kind: {kind}")
                    normal_lines.append(csv_line)
                    if any("\t" in str(props.get(h, "")) for h in headers):
                        tab_lines.append(csv_line)
                    if len(normal_lines) >= BATCH_SIZE:
                        await normal_f.write("".join(normal_lines))
                        normal_lines = []
                    if tab_lines and len(tab_lines) >= BATCH_SIZE:
                        if tab_file is None:
                            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                            tab_dir = os.path.join(
                                os.getcwd(), f"tab_replaced_{timestamp}"
                            )
                            os.makedirs(tab_dir, exist_ok=True)
                            tab_file_path = os.path.join(
                                tab_dir, f"{label.lower()}_tab_replaced.csv"
                            )
                            tab_file = await aiofiles.open(
                                tab_file_path, "w", encoding="utf-8", newline=""
                            )
                        await tab_file.write("".join(tab_lines))
                        tab_lines = []
                if normal_lines:
                    await normal_f.write("".join(normal_lines))
                if tab_lines:
                    if tab_file is None:
                        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                        tab_dir = os.path.join(os.getcwd(), f"tab_replaced_{timestamp}")
                        os.makedirs(tab_dir, exist_ok=True)
                        tab_file_path = os.path.join(
                            tab_dir, f"{label.lower()}_tab_replaced.csv"
                        )
                        tab_file = await aiofiles.open(
                            tab_file_path, "w", encoding="utf-8", newline=""
                        )
                    await tab_file.write("".join(tab_lines))
        finally:
            if tab_file is not None:
                await tab_file.close()
        if tab_file_path:
            log.warning("Tab characters in '%s'; mirror written to %s",
                        label, tab_file_path)
        return normal_file_path


async def main() -> None:
    p = argparse.ArgumentParser(description="agefreighter loader (typed)")
    p.add_argument("--pg-con-str", required=True)
    p.add_argument("--graphname", required=True)
    p.add_argument("--config", required=True)
    p.add_argument("--pg-min-connections", type=int, default=4)
    p.add_argument("--pg-max-connections", type=int, default=64)
    p.add_argument("--chunk-size", type=int, default=128)
    p.add_argument("--save-temps", action="store_true")
    p.add_argument("--progress", action="store_true")
    p.add_argument("--debug", action="store_true")
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    async with TypedCSVExporter(
        dsn=args.pg_con_str,
        min_connections=args.pg_min_connections,
        max_connections=args.pg_max_connections,
        config=os.path.abspath(args.config),
        trial=False,
        no_of_edges_trial=0,
        save_temps=args.save_temps,
        progress=args.progress,
        graph_name=args.graphname,
        chunk_size=args.chunk_size,
        log_level=logging.DEBUG if args.debug else logging.INFO,
    ) as exporter:
        await exporter.export()
        await exporter.copy()


if __name__ == "__main__":
    asyncio.run(main())
```

### 4.5 Run command

```bash
export CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/postgres"
cd ~/repositories/ldbc_snb_interactive_v1_impls/age

python3 scripts/load-with-agefreighter.py \
  --pg-con-str "host=localhost port=5432 dbname=postgres user=postgres password=postgres" \
  --graphname ldbc_snb \
  --config ~/repositories/GraphBenchmarking/ldbc_snb_benchmark/converted/sf3/agefreighter_config.json \
  --progress
```

After it finishes, run the same post-load steps as the existing flow:
```bash
psql "$CONNECTION_STRING" -f scripts/create-indexes.sql
bash scripts/vacuum-analyze.sh
bash scripts/snapshot-database.sh
```

### 4.6 Verification (must do before declaring success)

The implementing agent must run all of these and confirm the expected output. Failure of *any* check means the migration is not done.

```bash
# 0. Pre-req: LDBC SF0.1 already preprocessed at converted/sf0.1/ via preprocess_ldbc.py.
PG="host=localhost port=5432 dbname=postgres user=postgres password=postgres"
PGPASSWORD=postgres

# --- Run reference loader to a baseline DB ---
psql "$PG" -c "LOAD 'age'; SELECT drop_graph('ldbc_snb', true);" 2>/dev/null || true
python3 scripts/load-production-data.py \
  --config ~/repositories/GraphBenchmarking/ldbc_snb_benchmark/converted/sf0.1/agefreighter_config.json
psql "$PG" -f scripts/create-indexes.sql
bash scripts/vacuum-analyze.sh

# Capture vertex/edge counts and a few sample property fingerprints
psql "$PG" -tA -F'|' \
  -c "SET search_path = ag_catalog, public;
      SELECT 'Person', count(*) FROM ldbc_snb.\"Person\" UNION ALL
      SELECT 'Comment', count(*) FROM ldbc_snb.\"Comment\" UNION ALL
      SELECT 'Post', count(*) FROM ldbc_snb.\"Post\" UNION ALL
      SELECT 'KNOWS', count(*) FROM ldbc_snb.\"KNOWS\" UNION ALL
      SELECT 'HAS_CREATOR', count(*) FROM ldbc_snb.\"HAS_CREATOR\";" \
  > /tmp/baseline_counts.txt
psql "$PG" -tA \
  -c "SET search_path = ag_catalog, public;
      SELECT properties FROM ldbc_snb.\"Person\" ORDER BY id LIMIT 1;" \
  > /tmp/baseline_first_person.txt

# --- Repeat with the agefreighter-based loader ---
psql "$PG" -c "LOAD 'age'; SELECT drop_graph('ldbc_snb', true);" 2>/dev/null || true
python3 scripts/load-with-agefreighter.py \
  --pg-con-str "$PG" \
  --graphname ldbc_snb \
  --config ~/repositories/GraphBenchmarking/ldbc_snb_benchmark/converted/sf0.1/agefreighter_config.json
psql "$PG" -f scripts/create-indexes.sql
bash scripts/vacuum-analyze.sh

psql "$PG" -tA -F'|' \
  -c "SET search_path = ag_catalog, public;
      SELECT 'Person', count(*) FROM ldbc_snb.\"Person\" UNION ALL
      SELECT 'Comment', count(*) FROM ldbc_snb.\"Comment\" UNION ALL
      SELECT 'Post', count(*) FROM ldbc_snb.\"Post\" UNION ALL
      SELECT 'KNOWS', count(*) FROM ldbc_snb.\"KNOWS\" UNION ALL
      SELECT 'HAS_CREATOR', count(*) FROM ldbc_snb.\"HAS_CREATOR\";" \
  > /tmp/agefreighter_counts.txt

# Check 1: counts identical
diff /tmp/baseline_counts.txt /tmp/agefreighter_counts.txt
# Expected: empty diff. Counts must be:
#   Person: 1528, Comment: 151043, Post: 135701,
#   KNOWS: 28146, HAS_CREATOR: 286744 (Comment + Post hasCreator)

# Check 2: integer typing on Person.id
psql "$PG" -tA -c "SET search_path = ag_catalog, public;
  SELECT properties FROM ldbc_snb.\"Person\" ORDER BY id LIMIT 1;"
# Expected substring: "id": 933   (NOT "id": "933")

# Check 3: empty-string properties absent for image posts
psql "$PG" -tA -c "SET search_path = ag_catalog, public;
  SELECT count(*) FROM ldbc_snb.\"Post\" WHERE properties::text LIKE '%\": \"\"%';"
# Expected: 0

# Check 4: integer-literal MATCH succeeds (THE bug fix)
psql "$PG" -tA -c "LOAD 'age'; SET search_path = ag_catalog, public;
  SELECT * FROM cypher('ldbc_snb', \$\$
    MATCH (p:Person {id: 933}) RETURN p.firstName \$\$) AS (n agtype);"
# Expected: "Mahinda"

# Check 5: range filter on integer property (creationDate)
psql "$PG" -tA -c "LOAD 'age'; SET search_path = ag_catalog, public;
  SELECT * FROM cypher('ldbc_snb', \$\$
    MATCH (m:Comment) WHERE m.creationDate < 1300000000000 RETURN count(m) \$\$)
  AS (n agtype);"
# Expected: a non-zero integer (≈ 6000+ for SF0.1)

# Check 6: KNOWS bidirectionality (C3) — random sample
psql "$PG" -tA -c "LOAD 'age'; SET search_path = ag_catalog, public;
  SELECT * FROM cypher('ldbc_snb', \$\$
    MATCH (a:Person {id: 933})-[:KNOWS]->(b:Person)
    RETURN count(b) \$\$) AS (n agtype);
  SELECT * FROM cypher('ldbc_snb', \$\$
    MATCH (a:Person {id: 933})<-[:KNOWS]-(b:Person)
    RETURN count(b) \$\$) AS (n agtype);"
# Expected: same number for both directions (e.g., 30 / 30).

# Check 7: full subset validation passes against agefreighter-loaded DB
bash scripts/snapshot-database.sh
# Edit driver/validate.properties to point validate_database at the 2000-line subset
java -Xmx8g -cp target/age-1.2.0-SNAPSHOT.jar \
  org.ldbcouncil.snb.driver.Client -P driver/validate.properties
# Expected: only IC13 (96) and IC14 (96) marked Incorrect.
```

If Check 7 passes, the migration is correct. The README "Production data" section can then be flipped to recommend the agefreighter-based loader.

---

## 5. Plan B (parallel) — upstream PR

Open this independently of Plan A so we can retire Plan A faster.

### 5.1 Upstream change shape

In `agefreighter/agefreighter.py`:

```python
# new class attribute (default: behave exactly as today)
class AgeFreighter:
    numeric_keys: Set[str] = set()
    ...

    async def write_csv(self, label, kind, data):
        ...
        def format_kv(key, value):
            if key in self.numeric_keys:
                try:
                    return f'""{key}"": {int(float(value))}'
                except (TypeError, ValueError):
                    pass
            # ... existing string-quoting path unchanged
```

In `agefreighter/csvexporter.py`:

```python
# read numeric props from config
self.numeric_keys = set(config.get("numeric_props", []))
```

In `agefreighter_config.json` (add a top-level field):
```json
{
  "numeric_props": ["id", "creationDate", "birthday", "length",
                    "classYear", "workFrom", "joinDate"],
  "edge": [...],
  ...
}
```

The `preprocess_ldbc.py` in `~/repositories/GraphBenchmarking/ldbc_snb_benchmark/` should be updated in tandem to emit `numeric_props` in the generated config.

### 5.2 PR checklist
- [ ] Add `numeric_keys` attribute with default `set()` (preserves existing behavior).
- [ ] Modify `format_kv` (the closure in `write_csv`) to consult `numeric_keys`.
- [ ] Add a unit test that loads a tiny CSV with a numeric column, asserts the agtype JSON in the loaded label table contains `{"id": 1}` not `{"id": "1"}`.
- [ ] Update README to document `numeric_props` config field.
- [ ] Reference our LDBC SNB use case in the PR description (the SF3 bootstrap doc and this plan are the receipts).

When the PR merges and a release is published:
1. Delete `scripts/load-with-agefreighter.py`.
2. Replace its README section with a one-liner pointing to the upstream `agefreighter` CLI.
3. Update `preprocess_ldbc.py` (or our wrapper) to emit `numeric_props` in `agefreighter_config.json`.
4. Bump pinned version in `requirements.txt`.

---

## 6. What this plan does NOT do

- It does not remove `scripts/load-production-data.py`. Keep it as a fallback / debugging path. It is small, has one dependency (psycopg2), and is the only loader we know works at every SF.
- It does not touch the SF3 bootstrap doc in `~/repositories/GraphBenchmarking/`. The bootstrap's verification queries use string-literal IDs (`MATCH (p:Person {id: '933'})`); leave them, but add a note that `load-with-agefreighter.py` (or a Plan-B-merged agefreighter) is required for the actual benchmark workload.
- It does not fix IC13/IC14 — those need `shortestPath()` support in AGE (separate work).

---

## 7. Open questions for the human reviewer

1. Do we want to host a fork of `agefreighter` under the team's GitHub org so Plan B can be installed via `pip install git+https://github.com/<org>/agefreighter@typed-csv` while the upstream PR is in review? (Recommendation: yes.)
2. Does `preprocess_ldbc.py` belong in this repo's tree or stays in `GraphBenchmarking`? The agefreighter migration is cleaner if both repos can be updated atomically.
3. At SF1000, is the COPY pipeline in `agefreighter` (chunk-based, async) actually faster than `load-production-data.py` (single-threaded)? Worth measuring before committing to the migration. If agefreighter is *not* faster, Plan A's ROI shrinks and we may prefer to invest the time in upstream PR (Plan B) only.
