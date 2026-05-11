#!/usr/bin/env bash
# End-to-end local validation against a local AGE/PostgreSQL instance.
# Run from the age/ directory after building the JAR.
#
# Steps:
#   1. (Optional) Load test data: pass --load to trigger load-test-data.sh
#   2. Generate validation_params.csv using our implementation
#   3. Restore snapshot (resets IU mutations from step 2)
#   4. Run validate_database against the generated params
#
# Usage:
#   cd age
#   bash scripts/run-local-validation.sh [--load]
#
# Override the default connection:
#   CONNECTION_STRING="postgresql://user:pass@host:5432/db" bash scripts/run-local-validation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JAR="${AGE_DIR}/target/age-1.2.0-SNAPSHOT.jar"

export CONNECTION_STRING="${CONNECTION_STRING:-postgresql://postgres:postgres@localhost:5432/postgres}"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-/tmp/ldbc_snb_snapshot.dump}"

LOCAL_VALIDATE="${AGE_DIR}/driver/validate-local.properties"
LOCAL_CREATE_PARAMS="${AGE_DIR}/driver/create-validation-parameters-local.properties"

# ---- Parse connection details from CONNECTION_STRING -------------------------
# Expected format: postgresql://user:pass@host:port/dbname
_cs="${CONNECTION_STRING#postgresql://}"
_userpass="${_cs%%@*}"
_hostportdb="${_cs##*@}"
_LOCAL_USER="${_userpass%%:*}"
_LOCAL_PASS="${_userpass##*:}"
_LOCAL_HOSTPORT="${_hostportdb%%/*}"
_LOCAL_DB="${_hostportdb##*/}"
_LOCAL_ENDPOINT="${_LOCAL_HOSTPORT}/${_LOCAL_DB}"

# ---- Refresh CONNECTION endpoint in *-local.properties files -----------------
# The *-local.properties files are the canonical source for local SF runs and
# already point to local SF3 paths. We just refresh the endpoint/user/password
# from CONNECTION_STRING so the tester can override via env var.
fill_local_props() {
  local file="$1"
  sed -i.bak \
    -e "s|age_endpoint=.*|age_endpoint=${_LOCAL_ENDPOINT}|" \
    -e "s|age_user=.*|age_user=${_LOCAL_USER}|" \
    -e "s|age_password=.*|age_password=${_LOCAL_PASS}|" \
    "$file" && rm -f "$file.bak"
}

fill_local_props "${LOCAL_VALIDATE}"
fill_local_props "${LOCAL_CREATE_PARAMS}"

# ---- Optionally load test data -----------------------------------------------
if [[ "${1:-}" == "--load" ]]; then
  echo "=== Loading test data ==="
  bash "${SCRIPT_DIR}/load-test-data.sh"
fi

# ---- Check JAR exists --------------------------------------------------------
if [[ ! -f "${JAR}" ]]; then
  echo "ERROR: JAR not found at ${JAR}. Run: mvn clean package -DskipTests" >&2
  exit 1
fi

cd "${AGE_DIR}"

# ---- Step 0: Restore snapshot (reset any IU mutations from prior runs) -------
# create_validation must run against the same clean state validate_database will see,
# otherwise Update operations re-create entities (CREATE, not MERGE) and the captured
# expected results contain duplicates that the post-restore validate_database can't reproduce.
if [[ ! -f "${SNAPSHOT_FILE}" ]]; then
  echo "ERROR: Snapshot not found at ${SNAPSHOT_FILE}." >&2
  echo "       Run with --load first, or run scripts/snapshot-database.sh manually." >&2
  exit 1
fi
echo ""
echo "=== Pre-validation: restoring snapshot ==="
bash scripts/restore-database.sh

# ---- Step 1: Generate validation_params.csv ----------------------------------
echo ""
echo "=== Generating validation_params.csv ==="
java -cp "${JAR}" org.ldbcouncil.snb.driver.Client \
  -P "${LOCAL_CREATE_PARAMS}"

# ---- Step 2: Restore snapshot (reset IU mutations) ---------------------------
echo ""
echo "=== Restoring snapshot ==="
bash scripts/restore-database.sh

# ---- Step 3: Validate --------------------------------------------------------
echo ""
echo "=== Running validation ==="
java -cp "${JAR}" org.ldbcouncil.snb.driver.Client \
  -P "${LOCAL_VALIDATE}"

echo ""
echo "=== Validation complete ==="
