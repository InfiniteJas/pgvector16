#!/bin/bash
#
# Provisions an optimized PostgreSQL 16 instance with pgvector, credcheck,
# and auth_delay on RHEL/CentOS 8. Applies dynamic hardware-based tuning
# optimized for LLM/RAG workloads.
#
# Author: Olzhas Alseitov

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly DB_USER="app_user"
readonly DB_NAME="rag_database"
readonly PG_VERSION="16"
readonly PG_DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"

# =============================================================================
# LOGGING & UTILITIES
# =============================================================================
err() {
  echo "[ERROR] $*" >&2
}

info() {
  echo "[INFO] $*"
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "This script must be run as root. Please use sudo."
    exit 1
  fi
}

# =============================================================================
# INSTALLATION
# =============================================================================
install_packages() {
  info "Installing prerequisites and EPEL repository..."
  dnf update -y
  dnf install -y epel-release wget curl gnupg2

  info "Adding official PostgreSQL repository..."
  dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
  
  # Disable default AppStream postgresql module to avoid conflicts
  dnf -qy module disable postgresql

  info "Installing PostgreSQL 16, pgvector, and security modules..."
  dnf install -y postgresql16-server postgresql16-contrib pgvector_16 postgresql16-credcheck
}

initialize_cluster() {
  info "Initializing PostgreSQL cluster..."
  /usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup initdb
  systemctl enable postgresql-${PG_VERSION}
}

# =============================================================================
# CONFIGURATION & TUNING
# =============================================================================
configure_tuning() {
  local total_ram_kb total_ram_gb cpu_cores
  local shared_buffers_gb effective_cache_size_gb work_mem_mb maintenance_work_mem_mb max_connections

  info "Calculating tuning parameters based on system hardware..."
  total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  total_ram_gb=$((total_ram_kb / 1024 / 1024))
  cpu_cores=$(nproc)

  # Ensure at least 2GB fallback for calculation safety
  if [[ "${total_ram_gb}" -lt 2 ]]; then
    total_ram_gb=2
  fi

  # Dynamic calculations
  shared_buffers_gb=$(awk "BEGIN {v = ${total_ram_gb} * 0.25; if (v < 1) v = 1; printf \"%d\", v}")
  effective_cache_size_gb=$((total_ram_gb * 3 / 4))
  work_mem_mb=$((total_ram_gb * 4))
  maintenance_work_mem_mb=$((total_ram_gb * 64))
  max_connections=$((cpu_cores * 4))

  info "Applying tuning: ${shared_buffers_gb}GB shared_buffers, ${max_connections} max_connections"

  # Backup original config
  cp "${PG_DATA_DIR}/postgresql.conf" "${PG_DATA_DIR}/postgresql.conf.backup.$(date +%F)"
  
  cat > "${PG_DATA_DIR}/postgresql.conf" << EOF
# --- Optimized configuration for LLM/vector workloads ---
listen_addresses = '*'
port = 5432
max_connections = ${max_connections}

# Memory Settings
shared_buffers = ${shared_buffers_gb}GB
effective_cache_size = ${effective_cache_size_gb}GB
maintenance_work_mem = ${maintenance_work_mem_mb}MB
work_mem = ${work_mem_mb}MB

# WAL Settings
wal_buffers = 16MB
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9

# Worker Processes
effective_io_concurrency = 200
max_worker_processes = ${cpu_cores}
max_parallel_workers_per_gather = $((cpu_cores / 2))
max_parallel_workers = ${cpu_cores}
random_page_cost = 1.1

# Vacuum
autovacuum = on
autovacuum_max_workers = 4
autovacuum_naptime = 30s

# Logging
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %q%u@%d '
log_lock_waits = on
timezone = 'UTC'

# Security & Extensions
password_encryption = scram-sha-256
shared_preload_libraries = 'pg_stat_statements, auth_delay, credcheck'
auth_delay.milliseconds = 500
EOF

  # Configure HBA (Client Authentication)
  info "Configuring client authentication (pg_hba.conf)..."
  cp "${PG_DATA_DIR}/pg_hba.conf" "${PG_DATA_DIR}/pg_hba.conf.backup.$(date +%F)"
  
  cat > "${PG_DATA_DIR}/pg_hba.conf" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# WARNING: Replace 0.0.0.0/0 with the specific CIDR of your app host in production.
host    all             all             0.0.0.0/0               scram-sha-256
EOF
}

# =============================================================================
# DATABASE SETUP
# =============================================================================
setup_database() {
  local db_pass
  # Generate a 24-character alphanumeric password
  db_pass=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)

  info "Starting PostgreSQL service..."
  systemctl start postgresql-${PG_VERSION}
  
  # Wait for PG to become ready
  sleep 3 

  info "Creating database, user, and enabling pgvector..."
  su - postgres -c "psql -c \"CREATE USER ${DB_USER} WITH PASSWORD '${db_pass}';\""
  su - postgres -c "psql -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\""
  
  # Connect specifically to the new database to create the extension
  su - postgres -c "psql -d ${DB_NAME} -c \"CREATE EXTENSION IF NOT EXISTS vector;\""

  cat <<EOF

=====================================================
Provisioning Complete.
PostgreSQL 16 + pgvector is up and running.

Connection details:
  Host: <IP_of_this_server>
  Port: 5432
  User: ${DB_USER}
  Pass: ${db_pass}
  DB:   ${DB_NAME}
=====================================================
IMPORTANT: Save this password now. It will not be displayed again.
EOF
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
  check_root
  install_packages
  initialize_cluster
  configure_tuning
  setup_database
}

main "$@"
