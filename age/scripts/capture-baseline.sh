#!/usr/bin/env bash
# Capture the canonical SF3 benchmark baseline used by the regression gates.
#
# Runs the main-session final-gate benchmark profile (benchmark-local-20k by
# default) against the LOCAL database, then copies the driver's
# results/LDBC-results.json to baselines/bench-sf3-baseline.json. Both the
# implementer self-gate (10K) and the main-session final gate (20K) diff their
# runs against this one file.
#
# The baseline is MEASURED data — it can only be produced by running this script
# against a loaded, snapshotted SF3 database. It cannot be hand-written.
#
# Refuses any non-local CONNECTION_STRING: the baseline must never be captured
# against shared HorizonDB.
#
# Usage:
#   CONNECTION_STRING=postgresql://postgres:postgres@localhost:5432/postgres \
#     scripts/capture-baseline.sh [driver/<benchmark-profile>.properties]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILE="${1:-driver/benchmark-local-20k.properties}"
BASELINE="${AGE_DIR}/baselines/bench-sf3-baseline.json"
RESULTS="${AGE_DIR}/results/LDBC-results.json"

: "${CONNECTION_STRING:?CONNECTION_STRING environment variable must be set}"

# Local-only guard — never capture a baseline against shared HorizonDB.
case "$CONNECTION_STRING" in
  *localhost*|*127.0.0.1*) : ;;
  *) echo "ERROR: CONNECTION_STRING ($CONNECTION_STRING) is not local. Baseline capture is local-only."; exit 1 ;;
esac

cd "${AGE_DIR}"
mkdir -p baselines

echo "=== Capturing baseline with profile: ${PROFILE} ==="
bash scripts/restore-database.sh
bash driver/benchmark.sh "${PROFILE}" 2>&1 | tee "results/capture-baseline-$(date +%Y%m%d-%H%M%S).log"
bash scripts/restore-database.sh

if [[ ! -f "${RESULTS}" ]]; then
  echo "ERROR: expected ${RESULTS} after the run, but it is missing."
  exit 1
fi
cp "${RESULTS}" "${BASELINE}"
echo "=== Baseline written: ${BASELINE} ==="
echo "    Commit it so a fresh checkout has the reference fixture."
