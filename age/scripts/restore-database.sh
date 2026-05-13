#!/usr/bin/env bash
# Restore the database from a snapshot, then VACUUM ANALYZE.
# Run before each benchmark re-run to reset update-mutated state.
# Usage: ./restore-database.sh
set -euo pipefail

: "${CONNECTION_STRING:?CONNECTION_STRING environment variable must be set}"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-/tmp/ldbc_snb_snapshot.dump}"

echo "Restoring from snapshot: ${SNAPSHOT_FILE}"

# -------------------------------------------------------------------------
# 1. Clean up existing graph metadata and schema
# -------------------------------------------------------------------------
psql "$CONNECTION_STRING" -c "LOAD 'age'; SET search_path = ag_catalog, '\$user', public; SELECT drop_graph('ldbc_snb', true);" 2>/dev/null || true
psql "$CONNECTION_STRING" -c "DROP SCHEMA IF EXISTS ldbc_snb CASCADE;" 2>/dev/null || true

# -------------------------------------------------------------------------
# 2. Build a filtered TOC list for pg_restore.
#
#    A full pg_restore fails because "CREATE SCHEMA ag_catalog" errors out
#    (the extension already owns it).  pg_restore treats every ag_catalog
#    dependent — including all ldbc_snb tables that reference ag_catalog
#    types — as failed, so NOTHING gets restored.
#
#    Strategy: two targeted passes via TOC list files.
#      Pass A – restore everything in the ldbc_snb schema (DDL + data).
#      Pass B – restore only the ag_catalog TABLE DATA rows (ag_graph,
#               ag_label) so the OID-fix block below can correct them.
# -------------------------------------------------------------------------
FULL_TOC="$(mktemp)"
TOC_LDBC="$(mktemp)"
TOC_AGCAT="$(mktemp)"
trap 'rm -f "$FULL_TOC" "$TOC_LDBC" "$TOC_AGCAT"' EXIT

pg_restore --list "${SNAPSHOT_FILE}" > "$FULL_TOC" 2>/dev/null

# Pass A TOC: everything that belongs to ldbc_snb (DDL, data, indexes, …)
grep ' ldbc_snb ' "$FULL_TOC" > "$TOC_LDBC" || true
# Also include the CREATE SCHEMA line for ldbc_snb itself
grep 'SCHEMA - ldbc_snb ' "$FULL_TOC" >> "$TOC_LDBC" || true

# Pass B TOC: only ag_catalog TABLE DATA lines
grep 'TABLE DATA ag_catalog ' "$FULL_TOC" > "$TOC_AGCAT" || true

# -------------------------------------------------------------------------
# 3. Restore ldbc_snb schema + data
# -------------------------------------------------------------------------
echo "  Pass A: restoring ldbc_snb schema + data …"
pg_restore --no-owner --format=custom --use-list="$TOC_LDBC" \
  --dbname="$CONNECTION_STRING" "${SNAPSHOT_FILE}" 2>&1 | grep -i error || true

# -------------------------------------------------------------------------
# 4. Restore ag_catalog table data (ag_graph + ag_label rows)
# -------------------------------------------------------------------------
echo "  Pass B: restoring ag_catalog metadata (ag_graph / ag_label) …"
# Clear any stale rows so the COPY does not hit duplicate-key violations
psql "$CONNECTION_STRING" -c "
  ALTER TABLE ag_catalog.ag_label DISABLE TRIGGER ALL;
  ALTER TABLE ag_catalog.ag_graph DISABLE TRIGGER ALL;
  DELETE FROM ag_catalog.ag_label;
  DELETE FROM ag_catalog.ag_graph;
  ALTER TABLE ag_catalog.ag_graph ENABLE TRIGGER ALL;
  ALTER TABLE ag_catalog.ag_label ENABLE TRIGGER ALL;
" 2>/dev/null || true

pg_restore --no-owner --format=custom --use-list="$TOC_AGCAT" \
  --dbname="$CONNECTION_STRING" "${SNAPSHOT_FILE}" 2>&1 | grep -i error || true

# -------------------------------------------------------------------------
# 5. Fix OID mismatch.
#    pg_restore creates the ldbc_snb schema with a fresh OID, but the
#    dump's COPY data for ag_graph/ag_label carries the original OID.
# -------------------------------------------------------------------------
echo "  Fixing schema OID in ag_catalog …"
psql "$CONNECTION_STRING" <<'FIXSQL'
DO $$
DECLARE
  old_oid  oid;
  real_oid oid;
BEGIN
  SELECT graphid INTO old_oid  FROM ag_catalog.ag_graph WHERE name = 'ldbc_snb';
  SELECT oid     INTO real_oid FROM pg_catalog.pg_namespace WHERE nspname = 'ldbc_snb';
  IF old_oid IS NULL THEN
    RAISE EXCEPTION 'ag_catalog.ag_graph has no row for ldbc_snb – restore failed';
  END IF;
  IF old_oid IS DISTINCT FROM real_oid THEN
    ALTER TABLE ag_catalog.ag_label DISABLE TRIGGER ALL;
    ALTER TABLE ag_catalog.ag_graph DISABLE TRIGGER ALL;
    UPDATE ag_catalog.ag_graph SET graphid = real_oid WHERE name    = 'ldbc_snb';
    UPDATE ag_catalog.ag_label SET graph   = real_oid WHERE graph   = old_oid;
    ALTER TABLE ag_catalog.ag_graph ENABLE TRIGGER ALL;
    ALTER TABLE ag_catalog.ag_label ENABLE TRIGGER ALL;
  END IF;
END $$;
FIXSQL

echo "Recreating indexes after restore..."
psql "$CONNECTION_STRING" -f "$(dirname "$0")/create-indexes.sql" 2>&1 | grep -v NOTICE || true

echo "Running VACUUM ANALYZE after restore..."
bash "$(dirname "$0")/vacuum-analyze.sh"

echo "Restore complete."
