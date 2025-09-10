#!/bin/bash
# FINAL VERSION
# Provision an optimized PostgreSQL 16 + pgvector instance on RHEL/CentOS (EL8).
# - Generates a strong password for the application DB user
# - Applies sane defaults for vector-search and LLM workloads
# - Enables SCRAM-SHA-256 authentication and basic observability
#
# Author: Olzhas Alseitov

set -e

# =============================================================================
# SETTINGS (change as needed)
# =============================================================================
DB_USER="webui_user"
DB_NAME="open_webui_db"

echo "==> Installing optimized PostgreSQL 16 + pgvector (RHEL/CentOS EL8)"
echo "====================================================="

# 1) Detect system resources
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
CPU_CORES=$(nproc)

echo "==> Server: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores"

# 2) Compute tuning parameters (conservative, production-friendly defaults)
# - shared_buffers: ~25% RAM, min 1GB
# - effective_cache_size: ~75% RAM
# - work_mem: per-sort/per-hash (keep conservative)
# - maintenance_work_mem: for VACUUM/CREATE INDEX
# - max_connections: 4x CPU cores (adjust per workload)
SHARED_BUFFERS_GB=$(awk "BEGIN {v = ${TOTAL_RAM_GB} * 0.25; if (v < 1) v = 1; printf \"%d\", v}")
EFFECTIVE_CACHE_SIZE_GB=$((TOTAL_RAM_GB * 3 / 4))
WORK_MEM_MB=$((TOTAL_RAM_GB * 4))
MAINTENANCE_WORK_MEM_MB=$((TOTAL_RAM_GB * 64))
MAX_CONNECTIONS=$((CPU_CORES * 4))

echo "==> Tuning: shared_buffers=${SHARED_BUFFERS_GB}GB, work_mem=${WORK_MEM_MB}MB"
echo

# 3) Update system and base packages
echo "==> Updating system and installing prerequisites..."
sudo dnf update -y
sudo dnf install -y wget curl gnupg2

# 4) Add PostgreSQL repo and install PostgreSQL 16 + pgvector
echo "==> Adding official PostgreSQL repository..."
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql

echo "==> Installing PostgreSQL 16 and pgvector..."
sudo dnf install -y postgresql16-server postgresql16-contrib pgvector_16

# 5) Initialize cluster
echo "==> Initializing PostgreSQL cluster..."
sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
sudo systemctl enable --now postgresql-16

# 6) Apply optimized configuration
echo "==> Applying optimized configuration..."
sudo systemctl stop postgresql-16

PG_DATA_DIR="/var/lib/pgsql/16/data"

# Backup and write postgresql.conf
sudo cp "${PG_DATA_DIR}/postgresql.conf" "${PG_DATA_DIR}/postgresql.conf.backup.$(date +%F)"
sudo bash -c "cat > ${PG_DATA_DIR}/postgresql.conf" << EOF
# --- Optimized configuration for LLM/vector workloads ---
listen_addresses = '*'
port = 5432
max_connections = ${MAX_CONNECTIONS}
shared_buffers = ${SHARED_BUFFERS_GB}GB
effective_cache_size = ${EFFECTIVE_CACHE_SIZE_GB}GB
maintenance_work_mem = ${MAINTENANCE_WORK_MEM_MB}MB
work_mem = ${WORK_MEM_MB}MB
wal_buffers = 16MB
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
max_worker_processes = ${CPU_CORES}
max_parallel_workers_per_gather = $((CPU_CORES / 2))
max_parallel_workers = ${CPU_CORES}
autovacuum = on
autovacuum_max_workers = 4
autovacuum_naptime = 30s
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %q%u@%d '
log_lock_waits = on
timezone = 'UTC'
password_encryption = scram-sha-256
shared_preload_libraries = 'pg_stat_statements'
EOF

# Backup and write pg_hba.conf (allow external connections with SCRAM)
echo "==> Configuring client authentication (pg_hba.conf)..."
sudo cp "${PG_DATA_DIR}/pg_hba.conf" "${PG_DATA_DIR}/pg_hba.conf.backup.$(date +%F)"
sudo bash -c "cat > ${PG_DATA_DIR}/pg_hba.conf" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# WARNING: The line below allows connections from ANY IPv4 address.
# For production, replace 0.0.0.0/0 with the specific CIDR of your app host.
host    all             all             0.0.0.0/0               scram-sha-256
EOF

# 7) Start service
echo "==> Starting PostgreSQL..."
sudo systemctl start postgresql-16
sleep 5

# 8) Create DB user and database, enable pgvector
DB_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)

echo "==> Creating user ${DB_USER} and database ${DB_NAME}..."
sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
sudo -u postgres psql -d ${DB_NAME} -c "CREATE EXTENSION IF NOT EXISTS vector;"

# 9) Print connection info
cat <<EONFO
=====================================================
✅ Installation complete.
PostgreSQL 16 + pgvector is ready.

Connection details (password generated once):
  Host: <IP_of_this_server>
  Port: 5432
  User: ${DB_USER}
  Pass: ${DB_PASS}
  DB:   ${DB_NAME}
=====================================================
IMPORTANT: Save the password now; it will not be shown again.
EONFO
