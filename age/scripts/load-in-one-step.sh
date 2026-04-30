#!/bin/bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

. scripts/vars.sh

echo "==============================================================================="
echo "Loading the Apache AGE database"
echo "-------------------------------------------------------------------------------"
echo "AGE_CONNECTION_STRING: ${AGE_CONNECTION_STRING}"
echo "AGE_GRAPH_NAME:       ${AGE_GRAPH_NAME}"
echo "LDBC_SF:              ${LDBC_SF}"
echo "==============================================================================="

# Step 1: Ensure AGE extension is loaded
echo "Step 1: Ensuring AGE extension..."
psql "${AGE_CONNECTION_STRING}" -c "CREATE EXTENSION IF NOT EXISTS age;"
psql "${AGE_CONNECTION_STRING}" -c "LOAD 'age';"
psql "${AGE_CONNECTION_STRING}" -c "SET search_path = ag_catalog, public;"

# Step 2: Drop existing graph if present, create fresh
echo "Step 2: Creating graph ${AGE_GRAPH_NAME}..."
psql "${AGE_CONNECTION_STRING}" -c "SELECT drop_graph('${AGE_GRAPH_NAME}', true);" 2>/dev/null || true
psql "${AGE_CONNECTION_STRING}" -c "SELECT create_graph('${AGE_GRAPH_NAME}');"

# Step 3: Load data
echo "Step 3: Loading LDBC data..."
bash scripts/load-data.sh --sf "${LDBC_SF}" --connection-string "${AGE_CONNECTION_STRING}"

# Step 4: Create indexes
echo "Step 4: Creating indexes..."
bash scripts/create-indices.sh

# Step 5: Install PL/pgSQL functions (BFS for IC-13, etc.)
echo "Step 5: Installing PL/pgSQL functions..."
psql "${AGE_CONNECTION_STRING}" -f scripts/create-sp-functions.sql

# Step 6: VACUUM ANALYZE
echo "Step 6: Running VACUUM ANALYZE..."
bash scripts/vacuum-analyze.sh "${AGE_CONNECTION_STRING}"

echo "==============================================================================="
echo "Loading complete."
echo "==============================================================================="
