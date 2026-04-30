#!/bin/bash
# VACUUM ANALYZE after data loading or database restore
# Usage: bash vacuum-analyze.sh [CONNECTION_STRING]

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..
. scripts/vars.sh

CONNECTION_STRING="${1:-${AGE_CONNECTION_STRING}}"

echo "Running VACUUM ANALYZE..."
psql "$CONNECTION_STRING" -c "VACUUM (ANALYZE, VERBOSE);"
echo "VACUUM ANALYZE complete."
