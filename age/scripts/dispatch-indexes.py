#!/usr/bin/env python3
"""
Parallel index builder for LDBC SNB AGE schema.

Splits create-indexes.sql into per-table groups and runs them in parallel,
each group in its own psycopg2 connection with per-session maintenance_work_mem.

Usage:
    python3 dispatch-indexes.py \\
        --sql create-indexes.sql \\
        --connection-string postgresql://postgres:postgres@localhost:5432/postgres \\
        [--workers 4] \\
        [--maintenance-work-mem 8GB]
"""

import argparse
import multiprocessing
import os
import re
import sys

import psycopg2


def split_into_groups(sql_text):
    """Split SQL into per-table groups.

    Groups are identified by extracting the table name from each CREATE INDEX
    statement. Statements that share the same table name go into the same group.
    SET statements at the top are applied to every worker connection.
    """
    preamble = []
    groups = {}  # table_name -> [sql_statement, ...]

    # Strip single-line comments before splitting on semicolons so that
    # comment text containing ';' (e.g. "tiny vs the GIN on properties).")
    # does not create spurious empty/comment-only "statements".
    stripped = re.sub(r'--[^\n]*', '', sql_text)
    statements = [s.strip() for s in re.split(r';', stripped) if s.strip()]

    for stmt in statements:
        # SET statements go into preamble (applied by each worker)
        if re.match(r'\s*SET\b', stmt, re.IGNORECASE):
            preamble.append(stmt + ";")
            continue
        # Extract table name from CREATE INDEX ... ON schema."Table" (...)
        m = re.search(r'\bON\s+\w+\."(\w+)"\s*[(\s]', stmt, re.IGNORECASE)
        if m:
            tbl = m.group(1)
            groups.setdefault(tbl, []).append(stmt + ";")
        else:
            # Unrecognised non-comment statement — add to a catch-all group
            groups.setdefault("_misc", []).append(stmt + ";")

    return preamble, groups


def _run_group(args):
    """Worker: execute one group of index-creation statements."""
    connection_string, preamble, stmts, group_name, maintenance_work_mem = args
    conn = psycopg2.connect(connection_string)
    conn.autocommit = True
    cur = conn.cursor()
    try:
        cur.execute(f"SET maintenance_work_mem = '{maintenance_work_mem}'")
        cur.execute("SET search_path = ag_catalog, '$user', public")
        for stmt in stmts:
            try:
                cur.execute(stmt)
            except Exception as e:
                print(f"  [{group_name}] ERROR: {e} — statement: {stmt[:120]}", file=sys.stderr)
        print(f"  [{group_name}] done ({len(stmts)} statements)")
    finally:
        cur.close()
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="Run create-indexes.sql in parallel")
    parser.add_argument("--sql", required=True, help="Path to create-indexes.sql")
    parser.add_argument(
        "--connection-string",
        default=os.environ.get(
            "CONNECTION_STRING",
            "postgresql://postgres:postgres@localhost:5432/postgres",
        ),
    )
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--maintenance-work-mem", default="8GB")
    args = parser.parse_args()

    with open(args.sql, encoding="utf-8") as f:
        sql_text = f.read()

    preamble, groups = split_into_groups(sql_text)
    print(f"Dispatching {len(groups)} index groups across {args.workers} workers…")

    work = [
        (args.connection_string, preamble, stmts, name, args.maintenance_work_mem)
        for name, stmts in groups.items()
    ]

    with multiprocessing.Pool(processes=args.workers) as pool:
        pool.map(_run_group, work)

    print("Index dispatch complete.")


if __name__ == "__main__":
    main()
