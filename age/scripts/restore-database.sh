#!/bin/bash
# Restore database from pg_dump snapshot and run VACUUM ANALYZE
# Usage: bash restore-database.sh [CONNECTION_STRING] [DUMP_FILE]

CONNECTION_STRING="${1:-postgresql://postgres:postgres@localhost:5432/ldbcsnb}"
DUMP_FILE="${2:-ldbc_snb_snapshot.dump}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Restoring database from $DUMP_FILE..."
pg_restore --clean --if-exists -d "$CONNECTION_STRING" "$DUMP_FILE"
echo "Restore complete."

echo "Running VACUUM ANALYZE..."
bash "$SCRIPT_DIR/vacuum-analyze.sh" "$CONNECTION_STRING"
