#!/usr/bin/env bash
# Apply recommended PostgreSQL settings for LDBC SNB Interactive benchmarks.
# Targets Apache AGE 1.6 on PostgreSQL 17 with 32 vCPUs and 256 GB RAM.
#
# Usage:
#   sudo ./configure-postgres.sh --sf 0.1
#   sudo ./configure-postgres.sh --sf 100
#   sudo ./configure-postgres.sh --sf 1000
#
# The --sf argument scales work_mem and maintenance_work_mem:
#   SF0.1–SF1  : work_mem=128MB, maintenance_work_mem=2GB
#   SF10–SF100 : work_mem=512MB, maintenance_work_mem=4GB
#   SF1000     : work_mem=1GB,   maintenance_work_mem=8GB
#
# The script finds postgresql.conf via pg_lsclusters (Debian/Ubuntu) or
# pg_config (generic). Override by setting PGCONF env var.
# After editing, it reloads the server with pg_ctlcluster or pg_ctl.
set -euo pipefail

SF=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --sf) SF="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done
: "${SF:?--sf argument is required.  Example: sudo ./configure-postgres.sh --sf 0.1}"

# ---------------------------------------------------------------------------
# Scale work_mem and maintenance_work_mem based on SF.
# Rule of thumb: at SF N, the largest hash aggregations see ~N × baseline rows.
# Each of the 8 parallel workers per gather can consume work_mem simultaneously,
# so total memory for sort/hash = 8 × work_mem per query, multiplied by the
# number of concurrent driver threads (16 by default).
# Peak worst case at SF1000:  16 threads × 8 workers × 1 GB = 128 GB → fits
# in 256 GB box alongside 64 GB shared_buffers and OS page cache.
# ---------------------------------------------------------------------------
SF_NUM=$(echo "$SF" | awk '{printf "%f", $0}')

if awk "BEGIN{exit !($SF_NUM <= 1)}"; then
  WORK_MEM="128MB"
  MAINT_WORK_MEM="2GB"
elif awk "BEGIN{exit !($SF_NUM <= 100)}"; then
  WORK_MEM="512MB"
  MAINT_WORK_MEM="4GB"
else
  WORK_MEM="1GB"
  MAINT_WORK_MEM="8GB"
fi

echo "SF=${SF}  →  work_mem=${WORK_MEM}, maintenance_work_mem=${MAINT_WORK_MEM}"

# ---------------------------------------------------------------------------
# Locate postgresql.conf
# ---------------------------------------------------------------------------
if [[ -n "${PGCONF:-}" ]]; then
  CONF_FILE="$PGCONF"
elif command -v pg_lsclusters &>/dev/null; then
  # Debian/Ubuntu: pick the first running cluster
  CONF_FILE=$(pg_lsclusters --no-header | awk '/online/{print $6}' | head -1)
  [[ -z "$CONF_FILE" ]] && { echo "ERROR: no running PostgreSQL cluster found."; exit 1; }
elif command -v pg_config &>/dev/null; then
  CONF_FILE="$(pg_config --sysconfdir)/postgresql.conf"
  [[ -f "$CONF_FILE" ]] || CONF_FILE="$(pg_config --pkglibdir)/../../main/postgresql.conf"
else
  echo "ERROR: cannot find postgresql.conf. Set PGCONF=/path/to/postgresql.conf."
  exit 1
fi

[[ -f "$CONF_FILE" ]] || { echo "ERROR: postgresql.conf not found at: $CONF_FILE"; exit 1; }
echo "Editing: $CONF_FILE"

# ---------------------------------------------------------------------------
# Helper: set or replace a parameter in postgresql.conf.
# If the key already exists (active or commented), replace it; otherwise append.
# ---------------------------------------------------------------------------
set_param() {
  local key="$1"
  local value="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" "$CONF_FILE"; then
    sed -i.bak "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$CONF_FILE"
  else
    echo "${key} = ${value}" >> "$CONF_FILE"
  fi
  echo "  ${key} = ${value}"
}

# ---------------------------------------------------------------------------
# Apply settings
# ---------------------------------------------------------------------------
echo "--- Memory ---"
set_param "work_mem"                 "$WORK_MEM"
set_param "maintenance_work_mem"     "$MAINT_WORK_MEM"
# shared_buffers: 25% of RAM for dedicated DB hosts. On a 256GB machine = 64GB.
# Requires a full restart (not just reload) to take effect.
set_param "shared_buffers"           "64GB"

echo "--- Parallelism ---"
# 32 vCPUs: allow the planner to use up to 8 parallel workers per gather and
# keep ~24 of 32 cores available for parallel work, leaving ~8 for client
# connections, autovacuum, and the leader process.
set_param "max_worker_processes"            "32"
set_param "max_parallel_workers"            "24"
set_param "max_parallel_workers_per_gather" "8"
set_param "max_parallel_maintenance_workers" "8"
set_param "parallel_setup_cost"             "100"
set_param "parallel_tuple_cost"             "0.01"

echo "--- Planner cost (SSD / NVMe assumed) ---"
# random_page_cost=1.1 tells the planner SSD random I/O ≈ sequential I/O.
# This prevents it from preferring nested-loop seq scans over index scans on
# large edge tables at SF10+.
set_param "random_page_cost"         "1.1"
# effective_cache_size: planner hint, set to ~75% of total RAM so the planner
# prefers index scans by accounting for OS page cache. Does not allocate.
set_param "effective_cache_size"     "192GB"

echo "--- WAL / checkpoint ---"
set_param "wal_buffers"                     "256MB"
set_param "checkpoint_completion_target"    "0.9"
# max_wal_size: generous to reduce checkpoint frequency during bulk loads and
# IU-heavy benchmark runs on a host with plenty of disk and RAM.
set_param "max_wal_size"                    "16GB"
set_param "min_wal_size"                    "2GB"

echo "--- Connections / resources ---"
# 16 driver threads × Hikari pool + admin/autovacuum/replication overhead.
set_param "max_connections"                 "200"
# allow AGE's cypher() plans to stay in shared cache across connections
set_param "max_prepared_transactions"       "0"

echo ""
echo "--- Resulting settings ---"
grep -E "^(work_mem|maintenance_work_mem|shared_buffers|max_connections|max_worker_processes|max_parallel_workers|max_parallel_workers_per_gather|max_parallel_maintenance_workers|parallel_setup_cost|parallel_tuple_cost|random_page_cost|effective_cache_size|wal_buffers|checkpoint_completion_target|max_wal_size|min_wal_size)" "$CONF_FILE" | sort

# ---------------------------------------------------------------------------
# Reload PostgreSQL
# ---------------------------------------------------------------------------
echo ""
echo "--- Reloading PostgreSQL ---"
if command -v pg_ctlcluster &>/dev/null; then
  PG_VERSION=$(pg_lsclusters --no-header | awk '/online/{print $1}' | head -1)
  CLUSTER_NAME=$(pg_lsclusters --no-header | awk '/online/{print $2}' | head -1)
  pg_ctlcluster "$PG_VERSION" "$CLUSTER_NAME" reload
  echo "Reloaded cluster ${PG_VERSION} ${CLUSTER_NAME}."
elif command -v pg_ctl &>/dev/null; then
  PGDATA=$(psql -U postgres -tAc "SHOW data_directory;" 2>/dev/null || true)
  if [[ -n "$PGDATA" ]]; then
    pg_ctl reload -D "$PGDATA"
    echo "Reloaded PostgreSQL at $PGDATA."
  else
    echo "WARNING: could not determine PGDATA. Reload manually: pg_ctl reload -D <data_dir>"
  fi
else
  echo "WARNING: pg_ctlcluster / pg_ctl not found. Reload manually or restart PostgreSQL."
fi

echo ""
echo "Settings applied. Verify with:"
echo "  psql -U postgres -c \"SHOW work_mem; SHOW maintenance_work_mem; SHOW shared_buffers;\""
echo ""
echo "NOTE: shared_buffers, max_worker_processes, max_connections, and"
echo "      max_prepared_transactions all require a full RESTART (not just reload)"
echo "      to take effect. Other settings reload immediately."
