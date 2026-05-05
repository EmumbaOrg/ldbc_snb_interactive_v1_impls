#!/usr/bin/env python3
"""
Strip empty-string properties (content, language, imageFile) from Post vertices.

The load script omits empty values, but a prior load run left these as `""` in
the DB. coalesce(p.content, p.imageFile) then returns `""` for image posts
instead of the imageFile name. Run once after load to clean up.
"""
import json
import os
import sys
import psycopg2

CONNECTION_STRING = os.environ.get(
    "CONNECTION_STRING",
    "postgresql://postgres:postgres@localhost:5432/postgres",
)
GRAPH = os.environ.get("GRAPH_NAME", "ldbc_snb")
EMPTY_KEYS = ("content", "language", "imageFile")
BATCH = 5000


def main():
    conn = psycopg2.connect(CONNECTION_STRING)
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute("LOAD 'age'")
    cur.execute("SET search_path = ag_catalog, public")

    # Snapshot count before
    cur.execute(f'SELECT count(*) FROM {GRAPH}."Post"')
    total = cur.fetchone()[0]
    print(f"Total Posts: {total}")

    # Fetch all Posts with at least one empty string property
    cur.execute(
        f'''SELECT id, properties::text FROM {GRAPH}."Post"
            WHERE properties::text LIKE '%": ""%' '''
    )
    rows = cur.fetchall()
    print(f"Posts with empty-string property: {len(rows)}")

    updates = []
    for vid, props_text in rows:
        props = json.loads(props_text)
        changed = False
        for k in EMPTY_KEYS:
            if k in props and props[k] == "":
                del props[k]
                changed = True
        if changed:
            new_text = json.dumps(props, ensure_ascii=False)
            updates.append((new_text, vid))

    print(f"Updates to apply: {len(updates)}")
    if not updates:
        print("Nothing to do.")
        conn.close()
        return

    update_sql = f'UPDATE {GRAPH}."Post" SET properties = %s::agtype WHERE id = %s'
    for i in range(0, len(updates), BATCH):
        batch = updates[i : i + BATCH]
        cur.executemany(update_sql, batch)
        conn.commit()
        print(f"  batch {i // BATCH + 1}: committed {len(batch)} rows ({i + len(batch)}/{len(updates)})")

    # Verify
    cur.execute(
        f'''SELECT count(*) FROM {GRAPH}."Post"
            WHERE properties::text LIKE '%": ""%' '''
    )
    leftover = cur.fetchone()[0]
    print(f"Remaining empty-string posts: {leftover}")

    cur.close()
    conn.close()
    print("Done. Run vacuum-analyze.sh and snapshot-database.sh next.")


if __name__ == "__main__":
    main()
