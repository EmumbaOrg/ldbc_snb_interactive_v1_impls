#!/bin/bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

. scripts/vars.sh

echo "Creating indexes on AGE graph..."
psql "${AGE_CONNECTION_STRING}" -f scripts/create-indexes.sql
echo "Indexes created."
