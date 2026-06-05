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
#   --sf <N>              Scale factor (required). E.g. 0.1, 1, 3, 10, 100.
#   --skip-preprocess     Skip the CSV preprocessing step (Step 1). Assumes
#                         converted CSVs already exist under
#                         age/scripts/converted/sf<N>/{vertices,edges}/.
#                         The sanity check will fail if they are missing.
#   --workers N           Parallel workers for vertex/edge COPY and GIN build.
#                         Default: 6. (32 vCPU − buffer for Postgres workers.)
#   --index-workers N     Parallel workers for B-tree/functional index builds.
#                         Default: 4. (Index builds are memory-hungry.)
#
# Optional overrides (env vars):
#   LDBC_DATA_DIR    directory containing the social_network-sf<N>-CsvComposite-LongDateFormatter
#                    folder (default: ~/repositories/ldbc_snb_data/sf<N>)
#   SNAPSHOT_FILE    path for pg_dump snapshot  (default: /tmp/ldbc_snb_snapshot.dump)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${AGE_DIR}/results"
mkdir -p "${RESULTS_DIR}"

SF=""
SKIP_PREPROCESS=false
WORKERS=6
INDEX_WORKERS=4
while [[ $# -gt 0 ]]; do
  case $1 in
    --sf) SF="$2"; shift 2 ;;
    --skip-preprocess) SKIP_PREPROCESS=true; shift ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --index-workers) INDEX_WORKERS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done
: "${SF:?--sf argument is required.  Example: ./load-data.sh --sf 0.1}"
: "${CONNECTION_STRING:?CONNECTION_STRING environment variable must be set}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${RESULTS_DIR}/load-sf${SF}-${TIMESTAMP}.log"

# Tee all output to a timestamped log file.
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== Load log: ${LOG_FILE} ==="
echo "=== SF=${SF} workers=${WORKERS} index-workers=${INDEX_WORKERS} started at $(date) ==="

CONVERTED_DIR="${SCRIPT_DIR}/converted/sf${SF}"
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
  time "${PY}" "${SCRIPT_DIR}/preprocess_ldbc.py" "${PREPROCESS_ARGS[@]}"
fi

# Sanity check — preprocessing must produce exactly 11 vertex CSVs and 15 edge CSVs.
# Milestone A 2026-05-30: CommentRootPost and MessageByCreator side tables retired;
# no side table CSVs are emitted by preprocess_ldbc.py any more.
V_COUNT=$(ls "${CONVERTED_DIR}/vertices/"     2>/dev/null | wc -l | tr -d ' ')
E_COUNT=$(ls "${CONVERTED_DIR}/edges/"        2>/dev/null | wc -l | tr -d ' ')
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
# Vertices and edges load in parallel (--workers); GIN indexes are deferred to
# after all COPYs complete, then built in parallel.
time "${PY}" "${SCRIPT_DIR}/load-production-data.py" \
    --config "${CONVERTED_DIR}/agefreighter_config.json" \
    --connection-string "$CONNECTION_STRING" \
    --workers "${WORKERS}"

# ---------------------------------------------------------------------------
echo "=== Step 3: Creating query-performance indexes (parallel, ${INDEX_WORKERS} workers) ==="
# dispatch-indexes.py splits create-indexes.sql by table and runs each group
# in a dedicated connection with per-session maintenance_work_mem.
time "${PY}" "${SCRIPT_DIR}/dispatch-indexes.py" \
    --sql "${SCRIPT_DIR}/create-indexes.sql" \
    --connection-string "$CONNECTION_STRING" \
    --workers "${INDEX_WORKERS}" \
    --maintenance-work-mem "8GB"

# ---------------------------------------------------------------------------
echo "=== Step 3b: Post-load finalize (ANALYZE core tables) ==="
time psql "$CONNECTION_STRING" \
    -f "${SCRIPT_DIR}/post-load-finalize.sql" \
    2>&1 | grep -v NOTICE || true

# ---------------------------------------------------------------------------
# Step 3c: REMOVED Milestone A 2026-05-30.
# CommentRootPost and MessageByCreator side tables retired; load-side-tables.py
# no longer needed. _id_map is dropped inline via Python (same connection path
# used by load-production-data.py).
echo "=== Step 3c: Dropping _id_map (Milestone A: no side table loads remain) ==="
"${PY}" - <<'PYEOF' "$CONNECTION_STRING"
import sys, psycopg2
conn = psycopg2.connect(sys.argv[1])
conn.autocommit = True
cur = conn.cursor()
cur.execute('SET search_path = ldbc_snb, ag_catalog, public')
cur.execute('DROP TABLE IF EXISTS "_id_map" CASCADE')
conn.close()
print("  _id_map dropped.")
PYEOF

# ---------------------------------------------------------------------------
# Step 4 (VACUUM ANALYZE) intentionally omitted: post-load-finalize.sql
# already runs targeted ANALYZE on every table it touches, and a
# fresh load produces zero dead tuples so VACUUM has nothing to reclaim. The
# full-DB `VACUUM (ANALYZE, VERBOSE)` scanned ~150M heap rows at SF10 for no
# new information (~15-30 min wasted). restore-database.sh still runs
# vacuum-analyze.sh because pg_restore doesn't update planner stats.

# ---------------------------------------------------------------------------
echo "=== Step 5: Taking snapshot ==="
# This snapshot is the clean baseline used by restore-database.sh before each run.
time bash "${SCRIPT_DIR}/snapshot-database.sh"

echo ""
echo "=== Data load complete for SF${SF} at $(date) ==="
echo "=== Timing log: ${LOG_FILE} ==="
echo "    Run the benchmark with: java ... Client -P driver/benchmark.properties"
echo "    Before re-running:      bash scripts/restore-database.sh"
