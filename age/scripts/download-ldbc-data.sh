#!/usr/bin/env bash
# Download + extract + verify the official LDBC SNB Interactive v1 data needed for
# a local validate/benchmark run. Pulls three artifacts into age/datasets/:
#   1. Social network graph (CsvComposite + LongDateFormatter) for the scale factor
#   2. Substitution parameters for the scale factor
#   3. Validation params oracle (single tarball, covers SF0.1-SF10)
#
# This does NOT touch the database. It does not build the restore snapshot — run
#   bash scripts/load-data.sh --sf <N>
# afterwards to preprocess, load, index, and pg_dump the snapshot that
# restore-database.sh expects.
#
# Usage:
#   cd age
#   bash scripts/download-ldbc-data.sh [--sf <N>]      # default: 3
#
# Idempotent: if the extracted target already exists it is left untouched; if only
# the tarball is present it is re-extracted; otherwise it is downloaded (resumable).
set -euo pipefail

SF=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2;;
    --sf=*) SF="${1#*=}"; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "Unknown argument: $1 (try --help)" >&2; exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${AGE_DIR}/datasets"

for t in curl tar zstd; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "ERROR: '$t' not found on PATH — install it (see scripts/install-dependencies.sh)." >&2
    exit 1
  }
done

mkdir -p "${DATA_DIR}"
cd "${DATA_DIR}"

GRAPH_BASE="https://datasets.ldbcouncil.org/snb-interactive-v1"
PARAMS_BASE="https://datasets.ldbcouncil.org/snb-interactive-v1-parameters"
VALIDATION_URL="https://datasets.ldbcouncil.org/interactive-v1/validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst"

GRAPH_DIR="social_network-sf${SF}-CsvComposite-LongDateFormatter"
PARAMS_DIR="substitution_parameters-sf${SF}"
VALIDATION_CSV="validation_params-sf${SF}.csv"

# Download (resumable) + extract a tarball unless its extracted target is already present.
ensure() {
  local url="$1" target="$2" tarball
  tarball="$(basename "$url")"
  if [[ -e "$target" ]]; then
    echo "  have    ${target}"
    return
  fi
  if [[ -f "$tarball" ]]; then
    echo "  have    ${tarball}"
  else
    echo "  fetch   ${tarball}"
    curl -fL --retry 3 -C - -o "$tarball" "$url"
  fi
  echo "  extract ${tarball}"
  tar --use-compress-program=unzstd -xf "$tarball"
}

echo "==> LDBC SNB Interactive v1 — SF${SF} -> ${DATA_DIR}"
echo "[1/3] Social network graph"
ensure "${GRAPH_BASE}/${GRAPH_DIR}.tar.zst" "${GRAPH_DIR}"
echo "[2/3] Substitution parameters"
ensure "${PARAMS_BASE}/${PARAMS_DIR}.tar.zst" "${PARAMS_DIR}"
echo "[3/3] Validation params oracle (SF0.1-SF10)"
ensure "${VALIDATION_URL}" "${VALIDATION_CSV}"

echo "==> Verify"
fail=0
check() { if [[ -e "$1" ]]; then echo "  OK    $1"; else echo "  MISS  $1"; fail=1; fi; }

check "${GRAPH_DIR}/dynamic"
check "${GRAPH_DIR}/static"
check "${VALIDATION_CSV}"

# Substitution params: interactive_*_param.txt may be flat or double-nested
# (depends on the archive). Locate the directory that directly contains them.
params_loc=""
if ls "${PARAMS_DIR}"/interactive_*_param.txt >/dev/null 2>&1; then
  params_loc="${PARAMS_DIR}"
elif ls "${PARAMS_DIR}/${PARAMS_DIR}"/interactive_*_param.txt >/dev/null 2>&1; then
  params_loc="${PARAMS_DIR}/${PARAMS_DIR}"
fi
if [[ -n "$params_loc" ]]; then
  echo "  OK    ${params_loc}/interactive_*_param.txt"
else
  echo "  MISS  ${PARAMS_DIR}/interactive_*_param.txt"; fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "ERROR: verification failed — see MISS lines above." >&2
  exit 1
fi

echo ""
echo "Done. SF${SF} data is in ${DATA_DIR}."
if [[ "$params_loc" == "${PARAMS_DIR}/${PARAMS_DIR}" ]]; then
  echo "NOTE: substitution params are double-nested. A driver profile's"
  echo "      parameters_dir must point at: datasets/${params_loc}/"
fi
echo "Next: build the restore snapshot with"
echo "    bash scripts/load-data.sh --sf ${SF}"
