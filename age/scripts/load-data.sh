#!/usr/bin/env bash
# Load LDBC SNB data into Apache AGE / HorizonDB.
# Preprocessing is done via scripts/preprocess_ldbc.py (converts raw LDBC CSVs).
# Loading uses load-production-data.py which stores numeric properties as
# agtype integers — required for MATCH (n {id: X}) lookups to work correctly.
#
# Usage:
#   export CONNECTION_STRING="postgresql://user:pass@host:5432/db"
#   ./load-data.sh --sf 0.1
#   ./load-data.sh --sf 100
#   ./load-data.sh --sf 3 --skip-preprocess   # reuse already-converted CSVs
#
# Flags:
#   --sf <N>            Scale factor (required). E.g. 0.1, 1, 3, 10, 100.
#   --skip-preprocess   Skip the CSV preprocessing step (Step 1). Assumes
#                       converted CSVs already exist under
#                       age/scripts/converted/sf<N>/{vertices,edges}/.
#                       The sanity check will fail if they are missing.
#
# Optional overrides (env vars):
#   LDBC_DATA_DIR    directory containing the social_network-sf<N>-CsvComposite-LongDateFormatter
#                    folder (default: ~/repositories/ldbc_snb_data/sf<N>)
#   SNAPSHOT_FILE    path for pg_dump snapshot  (default: /tmp/ldbc_snb_snapshot.dump)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SF=""
SKIP_PREPROCESS=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --sf) SF="$2"; shift 2 ;;
    --skip-preprocess) SKIP_PREPROCESS=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done
: "${SF:?--sf argument is required.  Example: ./load-data.sh --sf 0.1}"
: "${CONNECTION_STRING:?CONNECTION_STRING environment variable must be set}"

CONVERTED_DIR="${SCRIPT_DIR}/converted/sf${SF}"
AGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV="${AGE_DIR}/.venv"
if [[ ! -x "${VENV}/bin/python3" ]]; then
  echo "Creating venv and installing psycopg2-binary..."
  python3 -m venv "${VENV}"
  "${VENV}/bin/pip" install -q psycopg2-binary
fi
PY="${VENV}/bin/python3"

# ---------------------------------------------------------------------------
if [[ "$SKIP_PREPROCESS" == true ]]; then
  echo "=== Step 1: Skipping preprocessing (--skip-preprocess) ==="
else
  echo "=== Step 1: Preprocessing LDBC SF${SF} data ==="
  PREPROCESS_ARGS=(--sf "${SF}")
  if [[ -n "${LDBC_DATA_DIR:-}" ]]; then
    PREPROCESS_ARGS+=(--data-dir "${LDBC_DATA_DIR}")
  fi
  "${PY}" "${SCRIPT_DIR}/preprocess_ldbc.py" "${PREPROCESS_ARGS[@]}"
fi

# Sanity check — preprocessing must produce exactly 11 vertex CSVs and 15 edge CSVs.
V_COUNT=$(ls "${CONVERTED_DIR}/vertices/" 2>/dev/null | wc -l | tr -d ' ')
E_COUNT=$(ls "${CONVERTED_DIR}/edges/"    2>/dev/null | wc -l | tr -d ' ')
if [[ "$V_COUNT" -ne 11 || "$E_COUNT" -ne 15 ]]; then
  echo "ERROR: expected 11 vertex files and 15 edge files, got ${V_COUNT}v / ${E_COUNT}e."
  echo "Check ${CONVERTED_DIR}."
  exit 1
fi
echo "  Preprocessing OK: ${V_COUNT} vertex files, ${E_COUNT} edge files."

# ---------------------------------------------------------------------------
echo "=== Step 2: Loading graph into AGE via load-production-data.py ==="
# load-production-data.py stores id/creationDate/joinDate/birthMonth/birthDay
# as agtype integers so Cypher equality lookups (MATCH (n {id: X})) work correctly.
# It also derives birthMonth and birthDay from birthday at load time for IC10.
"${PY}" "${SCRIPT_DIR}/load-production-data.py" \
    --config "${CONVERTED_DIR}/agefreighter_config.json" \
    --connection-string "$CONNECTION_STRING"

# ---------------------------------------------------------------------------
echo "=== Step 3: Creating query-performance indexes ==="
# Set maintenance_work_mem high so index builds on large edge tables don't spill to disk.
psql "$CONNECTION_STRING" \
    -c "SET maintenance_work_mem = '4GB';" \
    -f "${SCRIPT_DIR}/create-indexes.sql" \
    2>&1 | grep -v NOTICE || true

# ---------------------------------------------------------------------------
echo "=== Step 3b: Applying denormalised schema (columns + indexes + backfill) ==="
psql "$CONNECTION_STRING" \
    -f "${SCRIPT_DIR}/denormalize-schema.sql" \
    2>&1 | grep -v NOTICE || true

# ---------------------------------------------------------------------------
# Step 4 (VACUUM ANALYZE) intentionally omitted: denormalize-schema.sql
# section 7 already runs targeted ANALYZE on every table it touches, and a
# fresh load produces zero dead tuples so VACUUM has nothing to reclaim. The
# full-DB `VACUUM (ANALYZE, VERBOSE)` scanned ~150M heap rows at SF10 for no
# new information (~15-30 min wasted). restore-database.sh still runs
# vacuum-analyze.sh because pg_restore doesn't update planner stats.

# ---------------------------------------------------------------------------
echo "=== Step 5: Taking snapshot ==="
# This snapshot is the clean baseline used by restore-database.sh before each run.
bash "${SCRIPT_DIR}/snapshot-database.sh"

echo ""
echo "=== Data load complete for SF${SF} ==="
echo "    Run the benchmark with: java ... Client -P driver/benchmark.properties"
echo "    Before re-running:      bash scripts/restore-database.sh"
