#!/bin/bash
# Restore database for AGE by reloading test data from scratch.
# pg_restore doesn't work with AGE-managed tables because:
# 1. AGE owns the label tables and won't let pg_restore drop them
# 2. After drop_graph + pg_restore, graph OIDs change breaking existing connections
#
# Instead, we simply reload the test data which drops and recreates the graph.
# Usage: bash restore-database.sh [CONNECTION_STRING] [DUMP_FILE]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Restoring database by reloading test data..."
bash "$SCRIPT_DIR/load-test-data.sh"
echo "Restore complete."
