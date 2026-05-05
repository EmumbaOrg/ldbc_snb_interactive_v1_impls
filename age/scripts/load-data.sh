#!/bin/bash
# Load LDBC SNB data into Apache AGE using preprocess_ldbc.py + agefreighter
# Usage: bash load-data.sh --sf <scale_factor> [--connection-string <conn>]

set -euo pipefail

SF="0.1"
CONNECTION_STRING="postgresql://postgres:postgres@localhost:5432/ldbcsnb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --sf) SF="$2"; shift 2 ;;
    --connection-string) CONNECTION_STRING="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "=== LDBC SNB AGE Data Loading (SF${SF}) ==="

# Step 1: Preprocess
echo "Step 1: Preprocessing LDBC data..."
#python3 "${REPO_ROOT}/ldbc_snb_interactive_v1_impls/age/scripts/preprocess_ldbc.py" --sf "$SF"

# Step 2: Load with agefreighter
echo "Step 2: Loading data with agefreighter..."
CONVERTED_DIR="${REPO_ROOT}/ldbc_snb_interactive_v1_impls/age/scripts/converted/sf${SF}"
if [ -f "${CONVERTED_DIR}/agefreighter_config.json" ]; then
  agefreighter --graphname ldbc_snb --pg-con-str "$CONNECTION_STRING" load --source-type csv --config "${CONVERTED_DIR}/agefreighter_config.json" --progress
else
  echo "ERROR: agefreighter config not found at ${CONVERTED_DIR}/agefreighter_config.json"
  exit 1
fi

# Step 3: Create indexes
echo "Step 3: Creating indexes..."
psql "$CONNECTION_STRING" -f "$SCRIPT_DIR/create-indexes.sql"

# Step 4: VACUUM ANALYZE
echo "Step 4: Running VACUUM ANALYZE..."
bash "$SCRIPT_DIR/vacuum-analyze.sh" "$CONNECTION_STRING"

echo "=== Data loading complete ==="
