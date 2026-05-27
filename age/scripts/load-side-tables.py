#!/usr/bin/env python3
"""
Load CommentRootPost and MessageByCreator side tables from preprocess-emitted
CSVs via psycopg2 copy_expert (COPY ... FROM STDIN).

Replaces the \\copy-based path in denormalize-schema.sql, which failed when run
via `psql -f` with sed-substituted paths: the metacommand interaction with
psql variable substitution + grep-filtered stderr lost the TEMP TABLE between
CREATE and \\copy. copy_expert streams over the existing libpq connection so
it works against both local Docker and managed Horizon DB without needing
server-side file access.
"""

import argparse
import os
import sys
import time

import psycopg2


def _load(conn, csv_path, stage_ddl, copy_sql, insert_sqls, label):
    cur = conn.cursor()
    cur.execute("SET search_path = ldbc_snb, ag_catalog, public")
    # Bump work_mem so the hash join against _id_map (Comment subset ~300 MB
    # at SF3, ~9 GB at SF100) builds in memory instead of spilling to disk.
    cur.execute("SET work_mem = '4GB'")
    cur.execute(stage_ddl)
    t0 = time.monotonic()
    with open(csv_path, "rb") as f:
        cur.copy_expert(copy_sql, f)
    copy_secs = time.monotonic() - t0
    inserted = 0
    for sql in insert_sqls:
        cur.execute(sql)
        inserted += cur.rowcount
    conn.commit()
    print(f"  {label}: COPY {copy_secs:.1f}s, INSERT {inserted} rows")
    cur.close()


def load_crp(conn, csv_path):
    # JOIN against _id_map (indexed bigint lookup) instead of the AGE Comment
    # label table (agtype property extraction). Saves hours at SF100.
    _load(
        conn,
        csv_path,
        stage_ddl="""
            CREATE TEMP TABLE _crp_stage (
                comment_business_id   bigint,
                root_post_business_id bigint
            ) ON COMMIT DROP
        """,
        copy_sql="COPY _crp_stage FROM STDIN WITH (FORMAT csv, DELIMITER '|')",
        insert_sqls=[
            """
            INSERT INTO "CommentRootPost" (comment_id, comment_business_id, root_post_business_id)
            SELECT m.graphid, s.comment_business_id, s.root_post_business_id
            FROM _crp_stage s
            JOIN "_id_map" m
              ON m.label = 'Comment' AND m.business_id = s.comment_business_id
            ON CONFLICT (comment_id) DO NOTHING
            """
        ],
        label="CommentRootPost",
    )


def load_mbc(conn, csv_path):
    # JOIN against _id_map for graphid resolution (Post leg + Comment leg).
    # Replaces two full-table agtype-property scans of Post and Comment.
    _load(
        conn,
        csv_path,
        stage_ddl="""
            CREATE TEMP TABLE _mbc_stage (
                creator_business_id bigint,
                message_business_id bigint,
                creation_date       bigint,
                content             text,
                is_post             boolean
            ) ON COMMIT DROP
        """,
        copy_sql="COPY _mbc_stage FROM STDIN WITH (FORMAT csv, DELIMITER '|', NULL '')",
        insert_sqls=[
            # Post leg
            """
            INSERT INTO "MessageByCreator" (creator_business_id, message_business_id, message_id, creation_date, content, is_post)
            SELECT s.creator_business_id, s.message_business_id, m.graphid,
                   s.creation_date, NULLIF(s.content, ''), true
            FROM _mbc_stage s
            JOIN "_id_map" m
              ON m.label = 'Post' AND m.business_id = s.message_business_id
            WHERE s.is_post
            ON CONFLICT DO NOTHING
            """,
            # Comment leg
            """
            INSERT INTO "MessageByCreator" (creator_business_id, message_business_id, message_id, creation_date, content, is_post)
            SELECT s.creator_business_id, s.message_business_id, m.graphid,
                   s.creation_date, NULLIF(s.content, ''), false
            FROM _mbc_stage s
            JOIN "_id_map" m
              ON m.label = 'Comment' AND m.business_id = s.message_business_id
            WHERE NOT s.is_post
            ON CONFLICT DO NOTHING
            """,
        ],
        label="MessageByCreator",
    )


def drop_id_map(conn):
    """Drop the load-time _id_map mapping table after side tables are
    populated. The table is recreated on every load by load-production-data.py.
    """
    cur = conn.cursor()
    cur.execute("SET search_path = ldbc_snb, ag_catalog, public")
    cur.execute('DROP TABLE IF EXISTS "_id_map" CASCADE')
    conn.commit()
    cur.close()
    print("  _id_map: dropped")


def main():
    parser = argparse.ArgumentParser(description="Load CRP/MBC side tables from CSV")
    parser.add_argument("--crp-csv", required=True, help="commentRootPost.csv path")
    parser.add_argument("--mbc-csv", required=True, help="messageByCreator.csv path")
    parser.add_argument(
        "--connection-string",
        default=os.environ.get(
            "CONNECTION_STRING",
            "postgresql://postgres:postgres@localhost:5432/postgres",
        ),
    )
    args = parser.parse_args()

    for path in (args.crp_csv, args.mbc_csv):
        if not os.path.isfile(path):
            print(f"ERROR: CSV not found: {path}", file=sys.stderr)
            sys.exit(1)

    print(f"Connecting to: {args.connection_string}")
    conn = psycopg2.connect(args.connection_string)
    conn.autocommit = False
    try:
        load_crp(conn, args.crp_csv)
        load_mbc(conn, args.mbc_csv)
        drop_id_map(conn)
    finally:
        conn.close()
    print("Side tables loaded.")


if __name__ == "__main__":
    main()
