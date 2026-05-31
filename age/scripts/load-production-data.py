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
        [--connection-string postgresql://postgres:postgres@localhost:5432/postgres] \\
        [--workers 6]
"""

import argparse
import io
import json
import multiprocessing
import os
import sys
from collections import defaultdict
from pathlib import Path

import psycopg2
import psycopg2.extras

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
    """Drop (if exists) and recreate the graph with all labels.

    Aggressive cleanup: drop_graph + DROP SCHEMA CASCADE before create_graph.
    drop_graph alone is not reliable after failed prior loads — it can leave a
    standalone schema (no ag_graph row) that blocks create_graph with a
    pg_namespace unique-violation. Belt-and-suspenders here is cheap.
    """
    print("Setting up graph…")
    # 1. Drop via AGE (clears ag_graph + ag_label + schema if all consistent)
    cur.execute("SELECT count(*) FROM ag_catalog.ag_graph WHERE name = %s", (graph_name,))
    if cur.fetchone()[0] > 0:
        cur.execute(f"SELECT drop_graph('{graph_name}', true)")
    conn.commit()
    # 2. Belt-and-suspenders: if a schema with the same name persists outside
    #    of AGE's tracking (from a half-completed prior load), wipe it.
    cur.execute(f'DROP SCHEMA IF EXISTS "{graph_name}" CASCADE')
    conn.commit()

    cur.execute(f"SELECT create_graph('{graph_name}')")
    conn.commit()

    for lbl in VERTEX_LABELS:
        cur.execute(f"SELECT create_vlabel('{graph_name}', '{lbl}')")
    for lbl in EDGE_LABELS:
        cur.execute(f"SELECT create_elabel('{graph_name}', '{lbl}')")
    conn.commit()
    print("  Graph and labels created.")


def setup_id_map(conn, cur, graph_name):
    """Create the (label, business_id) -> graphid mapping table in the graph
    schema. Replaces the in-memory Python id_maps dict so the loader scales
    past SF100 (where the dict would exceed available RAM). UNLOGGED — we
    rebuild it on every load and don't need crash recovery.

    Edge load resolves via SQL JOIN against this table; it is dropped by
    load-data.sh after the load completes.
    """
    cur.execute(
        f'DROP TABLE IF EXISTS {graph_name}."_id_map" CASCADE'
    )
    # graphid column is ag_catalog.graphid (not bigint) so INSERT-SELECT into
    # AGE label tables doesn't need a per-row cast (no implicit bigint→graphid
    # cast exists). COPY parses graphid from text via graphid_in.
    cur.execute(
        f'CREATE UNLOGGED TABLE {graph_name}."_id_map" ('
        f'  label       text NOT NULL,'
        f'  business_id bigint NOT NULL,'
        f'  graphid     ag_catalog.graphid NOT NULL,'
        f'  PRIMARY KEY (label, business_id)'
        f')'
    )
    conn.commit()
    print("  _id_map table created.")


# ---------------------------------------------------------------------------
# COPY helpers
# ---------------------------------------------------------------------------

def copy_flush(cur, conn, sql, lines):
    """Flush a list of COPY lines to PostgreSQL."""
    buf = io.StringIO("".join(lines))
    cur.copy_expert(sql, buf)
    conn.commit()


# ---------------------------------------------------------------------------
# Vertex loading (worker function — runs in a subprocess)
# ---------------------------------------------------------------------------

def _load_vertex_worker(args):
    """Worker: load one vertex label. label_id is pre-fetched in the main
    process to avoid the catalog-visibility race that fires when workers
    query ag_label freshly after setup_graph in another connection.
    """
    connection_string, graph_name, label, label_id, csv_path = args
    conn, cur = connect(connection_string)
    try:
        load_vertex_csv(conn, cur, graph_name, label, label_id, csv_path)
    finally:
        cur.close()
        conn.close()
    return label


def load_vertex_csv(conn, cur, graph_name, label, label_id, csv_path):
    """
    Stream-load a preprocessed vertex file via COPY, and in the same pass
    write (label, business_id, graphid) rows into the _id_map table so edges
    and side tables can resolve graphids via indexed SQL JOIN instead of an
    in-memory Python dict.

    Input file format (no header), one row per line:
        <orig_id>|"<agtype_properties_csv_escaped>"

    The properties field is already CSV-quoted by preprocess.
    label_id is passed in from the main process — looked up there once, after
    setup_graph commits, where the catalog view is guaranteed consistent.
    """
    vertex_copy_sql = f'COPY {graph_name}."{label}" FROM STDIN (FORMAT CSV)'
    id_map_copy_sql = (
        f'COPY {graph_name}."_id_map" (label, business_id, graphid) '
        f'FROM STDIN (FORMAT CSV)'
    )

    vertex_lines = []
    id_map_lines = []
    entry_id = 1

    def flush():
        if vertex_lines:
            copy_flush(cur, conn, vertex_copy_sql, vertex_lines)
            copy_flush(cur, conn, id_map_copy_sql, id_map_lines)
            vertex_lines.clear()
            id_map_lines.clear()

    with open(csv_path, encoding="utf-8") as f:
        for line in f:
            pipe = line.find("|")
            if pipe < 0:
                continue
            orig_id = line[:pipe]
            props_csv = line[pipe + 1:]  # already includes the trailing \n
            graphid = make_graphid(label_id, entry_id)
            vertex_lines.append(f"{graphid},{props_csv}")
            id_map_lines.append(f"{label},{orig_id},{graphid}\n")
            entry_id += 1

            if len(vertex_lines) >= COPY_BATCH:
                flush()

    flush()

    # Advance the sequence so AGE assigns the next graphid correctly for IU ops.
    if entry_id > 1:
        cur.execute(
            f"SELECT setval('\"{graph_name}\".\"{label}_id_seq\"', {entry_id - 1}, true)"
        )
        conn.commit()

    print(f"  {label}: {entry_id - 1} vertices", flush=True)


# ---------------------------------------------------------------------------
# Edge loading (worker function — runs in a subprocess)
# ---------------------------------------------------------------------------

def _load_edge_worker(args):
    """Worker: load one edge label using SQL JOIN against _id_map for graphid
    resolution. No Python id_map dict is pickled — each worker streams its
    CSV and resolves business_id -> graphid in batches via indexed lookup on
    the shared _id_map table. label_id is pre-fetched in the main process.
    """
    connection_string, graph_name, label, label_id, csv_path = args
    conn, cur = connect(connection_string)
    try:
        load_edge_csv(conn, cur, graph_name, label, label_id, csv_path)
    finally:
        cur.close()
        conn.close()


def load_edge_csv(conn, cur, graph_name, label, label_id, csv_path):
    """
    Stream-load a preprocessed edge file via COPY.

    Input file format (no header), one row per line:
        <start_orig>|<end_orig>|<start_label>|<end_label>|"<agtype_properties_csv_escaped>"

    For each batch of rows we:
      1. Collect unique (label, business_id) pairs.
      2. Issue one SELECT per distinct vertex-label, fetching graphids from
         the _id_map table indexed by (label, business_id).
      3. Build COPY lines for the batch and flush to the edge table.

    Memory per worker is bounded by COPY_BATCH; no global id_map is held.
    label_id is passed in from the main process (catalog-visibility race fix).
    """
    copy_sql = (
        f'COPY {graph_name}."{label}" (id, start_id, end_id, properties) '
        f'FROM STDIN (FORMAT CSV)'
    )
    id_map_table = f'{graph_name}."_id_map"'

    batch = []  # list of (orig_start, orig_end, start_label, end_label, props_csv)
    entry_id = 1
    skipped = 0

    def flush_batch():
        nonlocal entry_id, skipped
        if not batch:
            return
        # Collect unique business_ids per vertex label seen in this batch.
        ids_by_label = defaultdict(set)
        for orig_start, orig_end, sl, el, _props in batch:
            ids_by_label[sl].add(int(orig_start))
            ids_by_label[el].add(int(orig_end))

        # Resolve via SQL (one round-trip per vertex label).
        resolved = {}
        for vlabel, bid_set in ids_by_label.items():
            cur.execute(
                f'SELECT business_id, graphid FROM {id_map_table} '
                f'WHERE label = %s AND business_id = ANY(%s)',
                (vlabel, list(bid_set)),
            )
            for bid, gid in cur.fetchall():
                resolved[(vlabel, bid)] = gid

        # Build COPY lines.
        lines = []
        for orig_start, orig_end, sl, el, props_csv in batch:
            start_gid = resolved.get((sl, int(orig_start)))
            end_gid = resolved.get((el, int(orig_end)))
            if start_gid is None or end_gid is None:
                skipped += 1
                continue
            edge_gid = make_graphid(label_id, entry_id)
            lines.append(f"{edge_gid},{start_gid},{end_gid},{props_csv}")
            entry_id += 1

        if lines:
            copy_flush(cur, conn, copy_sql, lines)
        batch.clear()

    with open(csv_path, encoding="utf-8") as f:
        for line in f:
            parts = line.split("|", 4)
            if len(parts) < 5:
                continue
            batch.append(tuple(parts))
            if len(batch) >= COPY_BATCH:
                flush_batch()

    flush_batch()

    if entry_id > 1:
        cur.execute(
            f"SELECT setval('\"{graph_name}\".\"{label}_id_seq\"', {entry_id - 1}, true)"
        )
        conn.commit()

    total = entry_id - 1
    suffix = f" ({skipped} skipped — vertex not in _id_map)" if skipped else ""
    print(f"  {label}: {total} edges{suffix}", flush=True)


# ---------------------------------------------------------------------------
# GIN indexes — deferred, built in parallel after all COPYs complete
# ---------------------------------------------------------------------------

def _create_gin_worker(args):
    """Worker: create GIN index for one vertex label."""
    connection_string, graph_name, label = args
    conn, cur = connect(connection_string)
    try:
        cur.execute(
            f'CREATE INDEX IF NOT EXISTS gin_{label.lower()} '
            f'ON {graph_name}."{label}" USING GIN (properties ag_catalog.gin_agtype_ops)'
        )
        conn.commit()
        print(f"  {label}: GIN index created")
    finally:
        cur.close()
        conn.close()


def create_gin_indexes_parallel(connection_string, graph_name, workers):
    print("Creating GIN indexes on vertex properties (parallel)…")
    gin_args = [(connection_string, graph_name, lbl) for lbl in VERTEX_LABELS]
    with multiprocessing.Pool(processes=workers) as pool:
        pool.map(_create_gin_worker, gin_args)


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
    parser.add_argument(
        "--workers",
        type=int,
        default=6,
        help="Parallel workers for vertex/edge COPY and GIN build (default: 6)",
    )
    args = parser.parse_args()

    config_path = Path(args.config)
    if not config_path.exists():
        sys.exit(f"Config not found: {config_path}")

    vertex_csvs, edge_csvs = parse_config(config_path)

    print(f"Connecting to: {args.connection_string}")
    conn, cur = connect(args.connection_string)

    # 1. Graph + labels + _id_map (DDL must complete before parallel COPY)
    setup_graph(conn, cur, args.graph_name)
    setup_id_map(conn, cur, args.graph_name)

    # 1b. Pre-fetch every label's ag_label.id in the main connection. Workers
    # used to call get_label_id themselves, which queried ag_catalog.ag_label
    # from a freshly-opened connection — that occasionally raced against the
    # catalog-visibility window after setup_graph and failed with "Label not
    # found". Looking up label_ids here (same session that did setup_graph)
    # is guaranteed to see the just-committed catalog state; passing the ids
    # to workers in args removes the race entirely.
    print("Pre-fetching label ids…")
    label_ids = {}
    for label in VERTEX_LABELS + EDGE_LABELS:
        label_ids[label] = get_label_id(cur, args.graph_name, label)
    conn.commit()
    cur.close()
    conn.close()

    # 2. Vertices — load in parallel, each worker writes both the vertex
    # rows and the (label, business_id, graphid) mapping into _id_map.
    print(f"Loading vertices (workers={args.workers})…")
    vertex_args = []
    for label in VERTEX_LABELS:
        csv_path = vertex_csvs.get(label)
        if not csv_path:
            print(f"  {label}: no CSV in config, skipping")
            continue
        if not Path(csv_path).exists():
            print(f"  {label}: CSV not found at {csv_path}, skipping")
            continue
        vertex_args.append((args.connection_string, args.graph_name, label, label_ids[label], csv_path))

    with multiprocessing.Pool(processes=args.workers) as pool:
        pool.map(_load_vertex_worker, vertex_args)

    # 3. GIN indexes — deferred to after all vertices, built in parallel.
    create_gin_indexes_parallel(args.connection_string, args.graph_name, args.workers)

    # 4. Edges — parallel. Workers resolve business_id -> graphid via batched
    # SQL JOIN against _id_map (no Python dict pickling). Scales to SF1000
    # because the mapping lives in PostgreSQL, not in process memory.
    print(f"Loading edges (workers={args.workers})…")
    edge_args = []
    for label in EDGE_LABELS:
        csv_path = edge_csvs.get(label)
        if not csv_path:
            print(f"  {label}: no CSV in config, skipping")
            continue
        if not Path(csv_path).exists():
            print(f"  {label}: CSV not found at {csv_path}, skipping")
            continue
        edge_args.append((args.connection_string, args.graph_name, label, label_ids[label], csv_path))

    with multiprocessing.Pool(processes=args.workers) as pool:
        pool.map(_load_edge_worker, edge_args)

    print("\nLoad complete. _id_map is retained for the post-load DROP "
          "step in load-data.sh.")


if __name__ == "__main__":
    main()
