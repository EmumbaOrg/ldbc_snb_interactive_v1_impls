#!/usr/bin/env bash
# Capture a benchmark baseline for the implementer self-gate to diff against.
# Runs the 20K benchmark on a freshly-restored local SF3 DB and saves the result
# as baselines/bench-sf3-baseline.json (the canonical baseline path — a committed fixture,
# kept outside the gitignored results/ dir so it is tracked and shared).
#
# Usage: CONNECTION_STRING=postgresql://postgres:postgres@localhost:5432/postgres \
#          scripts/capture-baseline.sh [benchmark-profile]
# Default profile: driver/benchmark-20k-5kwarmup.properties (matches the gate).
set -euo pipefail

: "${CONNECTION_STRING:?CONNECTION_STRING environment variable must be set}"

# Local-only guard: baselines (and any benchmark/write cycle) must never run against
# shared HorizonDB. Refuse anything that is not a local connection.
case "$CONNECTION_STRING" in
  *localhost*|*127.0.0.1*) ;;
  *) echo "REFUSING: CONNECTION_STRING is not local ($CONNECTION_STRING). Baselines run local-only." >&2; exit 1 ;;
esac

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/.."

PROFILE="${1:-driver/benchmark-20k-5kwarmup.properties}"
BASELINE="baselines/bench-sf3-baseline.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "==> Restore before"
bash scripts/restore-database.sh

echo "==> Benchmark ($PROFILE)"
bash driver/benchmark.sh "$PROFILE" 2>&1 | tee "results/bench-baseline-${STAMP}.log"

echo "==> Saving baseline -> $BASELINE"
mkdir -p "$(dirname "$BASELINE")"
cp results/LDBC-results.json "$BASELINE"

echo "==> Restore after"
bash scripts/restore-database.sh

echo "Baseline captured: $BASELINE (profile: $PROFILE, $STAMP)"
