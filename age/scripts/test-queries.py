#!/usr/bin/env python3
"""
Run each LDBC SNB query directly against Postgres using the SF0.1 validation params,
and print actual output vs expected output for quick correctness verification.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

# ── Config ───────────────────────────────────────────────────────────────────
GRAPH_NAME   = "ldbc_snb"
QUERY_DIR    = Path(__file__).parent.parent / "queries"
PARAMS_FILE  = Path("/tmp/ldbc_sf01/validation_params-sf0.1.csv")
PG_URI       = "postgresql://postgres:postgres@localhost:5432/postgres"

# ── Parameter key → (query_file, param_builder) ──────────────────────────────
def build_params(key, raw):
    """Return dict of $placeholder → substitution string for the given CSV entry."""

    def qi(v):   return str(int(v))          # integer literal
    def qs(v):   return "'" + str(v).replace("\\", "\\\\").replace("'", "\\'") + "'"

    if key == "personIdSQ1":
        return {"personId": qi(raw["personIdSQ1"])}
    if key == "personIdSQ2":
        return {"personId": qi(raw["personIdSQ2"])}
    if key == "personIdSQ3":
        return {"personId": qi(raw["personIdSQ3"])}
    if key == "messageIdContent":
        return {"messageId": qi(raw["messageIdContent"])}
    if key == "messageIdCreator":
        return {"messageId": qi(raw["messageIdCreator"])}
    if key == "messageForumId":
        return {"messageId": qi(raw["messageForumId"])}
    if key == "messageRepliesId":
        return {"messageId": qi(raw["messageRepliesId"])}
    if key == "personIdQ1":
        return {"personId": qi(raw["personIdQ1"]), "firstName": qs(raw["firstName"])}
    if key == "personIdQ2":
        return {"personId": qi(raw["personIdQ2"]), "maxDate": qi(raw["maxDate"])}
    if key == "personIdQ3":
        end = int(raw["startDate"]) + int(raw["durationDays"]) * 86400000
        return {
            "personId":    qi(raw["personIdQ3"]),
            "countryXName": qs(raw["countryXName"]),
            "countryYName": qs(raw["countryYName"]),
            "startDate":   qi(raw["startDate"]),
            "endDate":     str(end),
        }
    if key == "personIdQ4":
        end = int(raw["startDate"]) + int(raw["durationDays"]) * 86400000
        return {
            "personId":  qi(raw["personIdQ4"]),
            "startDate": qi(raw["startDate"]),
            "endDate":   str(end),
        }
    if key == "personIdQ5":
        return {"personId": qi(raw["personIdQ5"]), "minDate": qi(raw["minDate"])}
    if key == "personIdQ6":
        return {"personId": qi(raw["personIdQ6"]), "tagName": qs(raw["tagName"])}
    if key == "personIdQ7":
        return {"personId": qi(raw["personIdQ7"])}
    if key == "personIdQ8":
        return {"personId": qi(raw["personIdQ8"])}
    if key == "personIdQ9":
        return {"personId": qi(raw["personIdQ9"]), "maxDate": qi(raw["maxDate"])}
    if key == "personIdQ10":
        return {"personId": qi(raw["personIdQ10"]), "month": qi(raw["month"])}
    if key == "personIdQ11":
        return {
            "personId":    qi(raw["personIdQ11"]),
            "countryName": qs(raw["countryName"]),
            "workFromYear": qi(raw["workFromYear"]),
        }
    if key == "personIdQ12":
        return {"personId": qi(raw["personIdQ12"]), "tagClassName": qs(raw["tagClassName"])}
    return None


QUERY_MAP = {
    "personIdSQ1":    "interactive-short-1.sql",
    "personIdSQ2":    "interactive-short-2.sql",
    "personIdSQ3":    "interactive-short-3.sql",
    "messageIdContent": "interactive-short-4.sql",
    "messageIdCreator": "interactive-short-5.sql",
    "messageForumId":   "interactive-short-6.sql",
    "messageRepliesId": "interactive-short-7.sql",
    "personIdQ1":     "interactive-complex-1.sql",
    "personIdQ2":     "interactive-complex-2.sql",
    "personIdQ3":     "interactive-complex-3.sql",
    "personIdQ4":     "interactive-complex-4.sql",
    "personIdQ5":     "interactive-complex-5.sql",
    "personIdQ6":     "interactive-complex-6.sql",
    "personIdQ7":     "interactive-complex-7.sql",
    "personIdQ8":     "interactive-complex-8.sql",
    "personIdQ9":     "interactive-complex-9.sql",
    "personIdQ10":    "interactive-complex-10.sql",
    "personIdQ11":    "interactive-complex-11.sql",
    "personIdQ12":    "interactive-complex-12.sql",
}

# ── Collect one non-empty test case per query type ────────────────────────────
def load_test_cases(params_file, max_scan=50000):
    cases = {}
    with open(params_file) as f:
        for i, line in enumerate(f):
            if i >= max_scan:
                break
            line = line.strip()
            if not line:
                continue
            parts = line.split("|", 1)
            if len(parts) != 2:
                continue
            try:
                raw = json.loads(parts[0])
                expected_raw = parts[1]
            except json.JSONDecodeError:
                continue

            # Skip update entries (no matching query map key)
            for key in QUERY_MAP:
                if key in raw and key not in cases:
                    expected = expected_raw.strip()
                    # Prefer non-empty results
                    if expected not in ('"-1"', '[]', 'null', ''):
                        cases[key] = (raw, expected)
                        break
            if len(cases) == len(QUERY_MAP):
                break

    # Fill in any still-missing ones with whatever we can find (even empty)
    if len(cases) < len(QUERY_MAP):
        with open(params_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split("|", 1)
                if len(parts) != 2:
                    continue
                try:
                    raw = json.loads(parts[0])
                    expected = parts[1].strip()
                except json.JSONDecodeError:
                    continue
                for key in QUERY_MAP:
                    if key in raw and key not in cases:
                        cases[key] = (raw, expected)
    return cases


def substitute(sql, params, graph_name):
    result = sql.replace("$graphName", graph_name)
    # Sort by length desc so $startDate is replaced before $start etc.
    for k, v in sorted(params.items(), key=lambda x: -len(x[0])):
        result = result.replace(f"${k}", str(v))
    return result


def run_query(sql):
    result = subprocess.run(
        ["psql", PG_URI, "-c", sql, "--no-align", "--tuples-only", "--field-separator=|"],
        capture_output=True, text=True, timeout=30
    )
    return result.stdout.strip(), result.stderr.strip()


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else None

    print(f"Loading test cases from {PARAMS_FILE}...")
    cases = load_test_cases(PARAMS_FILE)
    print(f"Found test cases for {len(cases)}/{len(QUERY_MAP)} query types.\n")

    results = {}
    for key, sql_file in sorted(QUERY_MAP.items()):
        label = sql_file.replace(".sql", "")
        if target and target.lower() not in label.lower():
            continue
        if key not in cases:
            print(f"[{label}] SKIP — no test case found")
            continue

        raw, expected = cases[key]
        params = build_params(key, raw)
        if params is None:
            print(f"[{label}] SKIP — param builder missing")
            continue

        sql_path = QUERY_DIR / sql_file
        if not sql_path.exists():
            print(f"[{label}] SKIP — query file not found: {sql_path}")
            continue

        sql = substitute(sql_path.read_text(), params, GRAPH_NAME)

        print(f"{'='*70}")
        print(f"[{label}]  params: {params}")
        print(f"Expected: {expected[:200]}{'...' if len(expected) > 200 else ''}")
        try:
            out, err = run_query(sql)
        except subprocess.TimeoutExpired:
            print(f"RESULT:   *** TIMEOUT (>30s) ***")
            results[label] = "TIMEOUT"
            print()
            continue

        if err:
            print(f"RESULT:   *** ERROR ***\n{err[:400]}")
            results[label] = "ERROR"
        else:
            print(f"RESULT:   {out[:400]}{'...' if len(out) > 400 else ''}")
            results[label] = "OK"
        print()

    print(f"{'='*70}")
    print("Summary:")
    for label, status in sorted(results.items()):
        print(f"  {label}: {status}")


if __name__ == "__main__":
    main()
