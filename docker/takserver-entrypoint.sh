#!/usr/bin/env bash
# takserver-entrypoint.sh
# Main orchestrator for TAK Server Docker container initialization.
# Coordinates modular initialization scripts and launches TAK Server.
#
# Initialization sequence:
#   1. init-env.sh     - Environment setup and validation
#   2. init-config.sh  - CoreConfig setup with DB password injection
#   3. init-certs.sh   - Generate root CA, server, and client certificates
#   4. init-datapackages.sh - Create Data Packages for each user
#   5. init-admin.sh   - Elevate admin privileges (background, best-effort)
#   6. TAK Server startup via configureInDocker.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAK_INIT_LOG="/opt/tak/logs/init.log"

# Setup cleanup handler
cleanup_and_exit() {
  echo "TAK Server - shutdown signal received"
  [[ -n "${ADMIN_ELEVATION_PID:-}" ]] && kill -TERM "$ADMIN_ELEVATION_PID" 2>/dev/null || true
  exit 0
}
trap cleanup_and_exit SIGTERM SIGINT

# Logging helper
log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [${level}] ${message}" | tee -a "$TAK_INIT_LOG"
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }

# ============================================================================
# Main Initialization Sequence
# ============================================================================

main() {
  log_info "TAK Server Docker container starting..."
  log_info "Init log: $TAK_INIT_LOG"
  
  # Create log directory
  mkdir -p "$(dirname "$TAK_INIT_LOG")"
  
  # Step 1: Environment initialization
  log_info "Step 1/5: Environment initialization"
  if ! source "${SCRIPT_DIR}/init-env.sh"; then
    log_error "Environment initialization failed"
    exit 1
  fi
  if ! validate_environment; then
    log_error "Environment validation failed"
    exit 1
  fi
  if ! parse_hosts_and_users; then
    log_error "Host/user parsing failed"
    exit 1
  fi
  
  # Step 2: CoreConfig setup
  log_info "Step 2/5: CoreConfig setup"
  if ! source "${SCRIPT_DIR}/init-config.sh"; then
    log_error "CoreConfig setup failed"
    exit 1
  fi
  if ! setup_coreconfig; then
    log_error "CoreConfig setup failed"
    exit 1
  fi
  if ! setup_cert_metadata; then
    log_warn "Certificate metadata setup had issues"
  fi
  
  # Step 3: Certificate generation
  log_info "Step 3/5: Certificate generation"
  if ! source "${SCRIPT_DIR}/init-certs.sh"; then
    log_error "Certificate generation failed"
    exit 1
  fi
  if ! initialize_certificates; then
    log_error "Certificate generation failed"
    exit 1
  fi
  
  # Step 4: Data package creation
  log_info "Step 4/5: Data package creation"
  if ! source "${SCRIPT_DIR}/init-datapackages.sh"; then
    log_warn "Data package creation had errors"
  fi
  if ! initialize_datapackages; then
    log_warn "Data package creation had errors"
  fi
  
  # Step 5: Admin elevation (background, best-effort)
  log_info "Step 5/5: Starting admin elevation process (background)"
  (
    source "${SCRIPT_DIR}/init-admin.sh"
  ) &
  ADMIN_ELEVATION_PID=$!
  
  log_info "TAK Server initialization complete"
  log_info "Starting TAK Server application..."
  
  # Run TAK Server as PID 1 (MUST block and stay in foreground)
  exec /opt/tak/configureInDocker.sh init
}

main "$@"