#!/usr/bin/env python3
"""
Load preprocessed LDBC files into Apache AGE using PostgreSQL COPY.

Replaces `agefreighter --source-type csv` for the production pipeline.

ROOT CAUSE OF THE AGEFREIGHTER PROBLEM:
  agefreighter's format_kv() wraps every value in double-quotes, storing all
  properties as agtype strings — {"id": "933", "creationDate": "1266161530447"}.
  AGE queries use integer literals: MATCH (p:Person {id: 933}) compiles to
  properties @> '{"id": 933}'::agtype.  String "933" != integer 933 in agtype,
  so every MATCH returns 0 rows.

INPUT FORMAT (produced by preprocess_ldbc.py):
  Vertex line:  <orig_id>|"<agtype_properties_csv_escaped>"
  Edge line:    <start_orig>|<end_orig>|<start_label>|<end_label>|"<agtype_properties_csv_escaped>"

  The agtype properties are pre-built by preprocess (numeric type discrimination,
  array passthrough, string escaping, Person.birthMonth/birthDay derivation,
  NULL-field omission). This loader does pure text split + COPY; no Python
  per-row JSON construction. At SF10 that saved ~15-25 min of GIL-bound CPU.

Usage:
    python3 scripts/load-production-data.py \\
        --config converted/sf0.1/agefreighter_config.json \\
        [--graph-name ldbc_snb] \\
        [--connection-string postgresql://postgres:postgres@localhost:5432/postgres]
"""

import argparse
import io
import json
import os
import sys
from pathlib import Path

import psycopg2

GRAPH = "ldbc_snb"
COPY_BATCH = 50_000          # rows per COPY flush (keeps memory bounded)
ENTRY_ID_BITS = 48            # graphid = (ag_label.id << 48) | entry_sequence

VERTEX_LABELS = [
    "Person", "Comment", "Post", "Forum", "Tag", "TagClass",
    "City", "Country", "Continent", "Company", "University",
]

EDGE_LABELS = [
    "KNOWS", "HAS_CREATOR", "REPLY_OF", "CONTAINER_OF", "HAS_MEMBER",
    "HAS_MODERATOR", "LIKES", "HAS_INTEREST", "STUDY_AT", "WORK_AT",
    "IS_LOCATED_IN", "IS_PART_OF", "HAS_TYPE", "IS_SUBCLASS_OF", "HAS_TAG",
]


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

def connect(cs):
    conn = psycopg2.connect(cs)
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute("LOAD 'age'")
    cur.execute("SET search_path = ag_catalog, '$user', public")
    conn.commit()
    return conn, cur


# ---------------------------------------------------------------------------
# Graph / label management
# ---------------------------------------------------------------------------

def make_graphid(label_id, entry_id):
    """Compute the AGE graphid: (ag_label.id << 48) | entry_sequence."""
    return (label_id << ENTRY_ID_BITS) | entry_id


def get_label_id(cur, graph_name, label_name):
    """Return ag_catalog.ag_label.id for the given label."""
    cur.execute(
        """SELECT l.id
           FROM ag_catalog.ag_label l
           JOIN ag_catalog.ag_graph g ON l.graph = g.graphid
           WHERE g.name = %s AND l.name = %s""",
        (graph_name, label_name),
    )
    row = cur.fetchone()
    if row is None:
        raise RuntimeError(f"Label not found: {label_name!r} in graph {graph_name!r}")
    return row[0]


def setup_graph(conn, cur, graph_name):
    """Drop (if exists) and recreate the graph with all labels."""
    print("Setting up graph…")
    cur.execute("SELECT count(*) FROM ag_catalog.ag_graph WHERE name = %s", (graph_name,))
    if cur.fetchone()[0] > 0:
        cur.execute(f"SELECT drop_graph('{graph_name}', true)")
    conn.commit()
    cur.execute(f"SELECT create_graph('{graph_name}')")
    conn.commit()

    for lbl in VERTEX_LABELS:
        cur.execute(f"SELECT create_vlabel('{graph_name}', '{lbl}')")
    for lbl in EDGE_LABELS:
        cur.execute(f"SELECT create_elabel('{graph_name}', '{lbl}')")
    conn.commit()
    print("  Graph and labels created.")


# ---------------------------------------------------------------------------
# COPY helpers
# ---------------------------------------------------------------------------

def copy_flush(cur, conn, sql, lines):
    """Flush a list of COPY lines to PostgreSQL."""
    buf = io.StringIO("".join(lines))
    cur.copy_expert(sql, buf)
    conn.commit()


# ---------------------------------------------------------------------------
# Vertex loading
# ---------------------------------------------------------------------------

def load_vertex_csv(conn, cur, graph_name, label, csv_path):
    """
    Stream-load a preprocessed vertex file via COPY.

    Input file format (no header), one row per line:
        <orig_id>|"<agtype_properties_csv_escaped>"

    The properties field is already CSV-quoted by preprocess (internal `"`
    doubled). We just prepend the graphid and stream straight to COPY.

    Returns {original_id_str: graphid} for downstream edge resolution.
    """
    label_id = get_label_id(cur, graph_name, label)
    copy_sql = f'COPY {graph_name}."{label}" FROM STDIN (FORMAT CSV)'

    id_map = {}
    lines = []
    entry_id = 1

    with open(csv_path, encoding="utf-8") as f:
        for line in f:
            pipe = line.find("|")
            if pipe < 0:
                continue
            orig_id = line[:pipe]
            props_csv = line[pipe + 1:]  # already includes the trailing \n
            graphid = make_graphid(label_id, entry_id)
            id_map[orig_id] = graphid
            lines.append(f"{graphid},{props_csv}")
            entry_id += 1

            if len(lines) >= COPY_BATCH:
                copy_flush(cur, conn, copy_sql, lines)
                lines = []

    if lines:
        copy_flush(cur, conn, copy_sql, lines)

    # Advance the sequence so AGE assigns the next graphid correctly for IU ops.
    if entry_id > 1:
        cur.execute(
            f"SELECT setval('\"{graph_name}\".\"{label}_id_seq\"', {entry_id - 1}, true)"
        )
        conn.commit()

    print(f"  {label}: {entry_id - 1} vertices")
    return id_map


# ---------------------------------------------------------------------------
# Edge loading
# ---------------------------------------------------------------------------

def load_edge_csv(conn, cur, graph_name, label, csv_path, id_maps):
    """
    Stream-load a preprocessed edge file via COPY.

    Input file format (no header), one row per line:
        <start_orig>|<end_orig>|<start_label>|<end_label>|"<agtype_properties_csv_escaped>"

    Properties are already CSV-quoted by preprocess. We resolve start/end
    orig_ids to graphids via id_maps and emit a four-column COPY line.

    id_maps: {label_name: {original_id_str: graphid}}
    """
    label_id = get_label_id(cur, graph_name, label)
    copy_sql = (
        f'COPY {graph_name}."{label}" (id, start_id, end_id, properties) '
        f'FROM STDIN (FORMAT CSV)'
    )

    lines = []
    entry_id = 1
    skipped = 0

    with open(csv_path, encoding="utf-8") as f:
        for line in f:
            parts = line.split("|", 4)
            if len(parts) < 5:
                continue
            orig_start, orig_end, start_label, end_label, props_csv = parts

            start_gid = id_maps.get(start_label, {}).get(orig_start)
            end_gid = id_maps.get(end_label, {}).get(orig_end)
            if start_gid is None or end_gid is None:
                skipped += 1
                continue

            edge_gid = make_graphid(label_id, entry_id)
            lines.append(f"{edge_gid},{start_gid},{end_gid},{props_csv}")
            entry_id += 1

            if len(lines) >= COPY_BATCH:
                copy_flush(cur, conn, copy_sql, lines)
                lines = []

    if lines:
        copy_flush(cur, conn, copy_sql, lines)

    if entry_id > 1:
        cur.execute(
            f"SELECT setval('\"{graph_name}\".\"{label}_id_seq\"', {entry_id - 1}, true)"
        )
        conn.commit()

    total = entry_id - 1
    suffix = f" ({skipped} skipped — vertex not found in id_map)" if skipped else ""
    print(f"  {label}: {total} edges{suffix}")


# ---------------------------------------------------------------------------
# GIN indexes (before edge loading for fast vertex lookup)
# ---------------------------------------------------------------------------

def create_gin_indexes(conn, cur, graph_name):
    print("Creating GIN indexes on vertex properties…")
    for label in VERTEX_LABELS:
        cur.execute(
            f'CREATE INDEX IF NOT EXISTS gin_{label.lower()} '
            f'ON {graph_name}."{label}" USING GIN (properties ag_catalog.gin_agtype_ops)'
        )
        conn.commit()
        print(f"  {label}: GIN index created")


# ---------------------------------------------------------------------------
# Config parsing
# ---------------------------------------------------------------------------

def parse_config(config_path):
    """
    Extract unique vertex and edge CSV paths from agefreighter_config.json.
    Returns:
      vertex_csvs: {label: csv_path}
      edge_csvs:   {edge_type: csv_path}
    """
    with open(config_path, encoding="utf-8") as f:
        cfg = json.load(f)

    vertex_csvs = {}
    edge_csvs = {}

    edge_entries = cfg["edge"]
    if isinstance(edge_entries, dict):
        edge_entries = [edge_entries]

    for entry in edge_entries:
        etype = entry.get("type")
        if etype and etype not in edge_csvs:
            edge_csvs[etype] = entry["csv_path"]
        for vkey in ("start_vertex", "end_vertex", "vertex"):
            vspec = entry.get(vkey)
            if vspec:
                lbl = vspec["label"]
                if lbl not in vertex_csvs:
                    vertex_csvs[lbl] = vspec["csv_path"]

    return vertex_csvs, edge_csvs


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Load LDBC data into Apache AGE via COPY")
    parser.add_argument("--config", required=True, help="Path to agefreighter_config.json")
    parser.add_argument(
        "--connection-string",
        default=os.environ.get(
            "CONNECTION_STRING",
            "postgresql://postgres:postgres@localhost:5432/postgres",
        ),
    )
    parser.add_argument("--graph-name", default=GRAPH)
    args = parser.parse_args()

    config_path = Path(args.config)
    if not config_path.exists():
        sys.exit(f"Config not found: {config_path}")

    vertex_csvs, edge_csvs = parse_config(config_path)

    print(f"Connecting to: {args.connection_string}")
    conn, cur = connect(args.connection_string)

    # 1. Graph + labels
    setup_graph(conn, cur, args.graph_name)

    # 2. Vertices
    print("Loading vertices…")
    id_maps = {}
    for label in VERTEX_LABELS:
        csv_path = vertex_csvs.get(label)
        if not csv_path:
            print(f"  {label}: no CSV in config, skipping")
            continue
        if not Path(csv_path).exists():
            print(f"  {label}: CSV not found at {csv_path}, skipping")
            continue
        id_maps[label] = load_vertex_csv(conn, cur, args.graph_name, label, csv_path)

    # 3. GIN indexes (must precede edge loading — edge MATCH lookups use them)
    create_gin_indexes(conn, cur, args.graph_name)

    # 4. Edges
    print("Loading edges…")
    for label in EDGE_LABELS:
        csv_path = edge_csvs.get(label)
        if not csv_path:
            print(f"  {label}: no CSV in config, skipping")
            continue
        if not Path(csv_path).exists():
            print(f"  {label}: CSV not found at {csv_path}, skipping")
            continue
        load_edge_csv(conn, cur, args.graph_name, label, csv_path, id_maps)

    cur.close()
    conn.close()
    print("\nLoad complete. Run scripts/create-indexes.sql and scripts/vacuum-analyze.sh next.")


if __name__ == "__main__":
    main()
