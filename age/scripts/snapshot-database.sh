#!/bin/bash
# Snapshot database using pg_dump before IU runs
# Usage: bash snapshot-database.sh [CONNECTION_STRING] [DUMP_FILE]

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..
. scripts/vars.sh

CONNECTION_STRING="${1:-${AGE_CONNECTION_STRING}}"
DUMP_FILE="${2:-ldbc_snb_snapshot.dump}"

echo "Creating database snapshot to $DUMP_FILE..."
pg_dump "$CONNECTION_STRING" -Fc -f "$DUMP_FILE"
echo "Snapshot complete: $DUMP_FILE"
