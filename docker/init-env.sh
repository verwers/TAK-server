#!/usr/bin/env bash
# init-env.sh
# Environment initialization and validation for TAK Server.
# Sets up directories, validates required variables, and provides logging setup.

set -euo pipefail

# ============================================================================
# Common Variables & Setup
# ============================================================================

export TAK_INIT_LOG="${TAK_INIT_LOG:-/opt/tak/logs/init.log}"
export CERT_DIR="${CERT_DIR:-/opt/tak/certs}"
export FILES_DIR="${FILES_DIR:-${CERT_DIR}/files}"
export CORE_EXAMPLE="${CORE_EXAMPLE:-/opt/tak/CoreConfig.example.xml}"
export CORE_CFG="${CORE_CFG:-/opt/tak/CoreConfig.xml}"

# Setup logging
mkdir -p "$(dirname "$TAK_INIT_LOG")" "${FILES_DIR}"

# Logging functions
log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [${level}] ${message}" | tee -a "$TAK_INIT_LOG"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && log "DEBUG" "$@"; }

export -f log log_info log_warn log_error log_debug

# ============================================================================
# Environment Variables with Defaults
# ============================================================================

: "${CA_NAME:=TAK-Root-CA}"
: "${SERVER_HOSTNAMES:=takserver,localhost}"
: "${CLIENT_NAMES:=client}"
: "${TAK_CERT_PASSWORD:=atakatak}"
: "${TAK_DB_PASSWORD:=atakatak}"
: "${MULTI_HOST_DP:=false}"
: "${COUNTRY:=US}"
: "${STATE:=XX}"
: "${CITY:=XX}"
: "${ORGANIZATION:=TAK}"
: "${ORGANIZATIONAL_UNIT:=TAK}"

export CA_NAME SERVER_HOSTNAMES CLIENT_NAMES TAK_CERT_PASSWORD TAK_DB_PASSWORD
export MULTI_HOST_DP COUNTRY STATE CITY ORGANIZATION ORGANIZATIONAL_UNIT

# ============================================================================
# Utility Functions
# ============================================================================

# Split comma-separated values into an array, trimming whitespace
split_csv() {
  local raw="$1" item
  local -a _parts=()
  IFS=',' read -ra _parts <<< "${raw}"
  for item in "${_parts[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

export -f split_csv

# Parse hostnames and client names
parse_hosts_and_users() {
  mapfile -t HOSTS < <(split_csv "${SERVER_HOSTNAMES}")
  mapfile -t USERS < <(split_csv "${CLIENT_NAMES}")
  
  if [[ ${#HOSTS[@]} -lt 1 ]]; then
    log_error "SERVER_HOSTNAMES is empty"
    return 1
  fi
  
  export HOSTS USERS
  export CANONICAL_HOST="${HOSTS[0]}"
  
  log_info "Server hostnames: ${HOSTS[*]}"
  log_info "Client names: ${USERS[*]}"
  log_info "Canonical hostname: $CANONICAL_HOST"
  
  return 0
}

export -f parse_hosts_and_users

# ============================================================================
# Pre-flight Validation
# ============================================================================

validate_environment() {
  log_info "Validating environment..."
  
  local errors=0
  
  if [[ -z "${SERVER_HOSTNAMES}" ]]; then
    log_error "SERVER_HOSTNAMES is not set"
    ((++errors))
  fi
  
  if [[ -z "${CLIENT_NAMES}" ]]; then
    log_error "CLIENT_NAMES is not set"
    ((++errors))
  fi
  
  if [[ -z "${TAK_CERT_PASSWORD}" ]]; then
    log_error "TAK_CERT_PASSWORD is not set"
    ((++errors))
  fi
  
  if [[ ! -f "${CORE_EXAMPLE}" ]]; then
    log_error "CoreConfig.example.xml not found at $CORE_EXAMPLE"
    ((++errors))
  fi
  
  if [[ $errors -gt 0 ]]; then
    log_error "Environment validation failed with $errors error(s)"
    return 1
  fi
  
  log_info "Environment validation passed"
  return 0
}

export -f validate_environment

# ============================================================================
# Initialization Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  log_info "TAK Server environment initialization"
  log_info "Log: $TAK_INIT_LOG"
  
  if ! validate_environment; then
    log_error "Pre-flight validation failed"
    exit 1
  fi
  
  if ! parse_hosts_and_users; then
    log_error "Failed to parse hosts and users"
    exit 1
  fi
  
  log_info "Environment initialization complete"
fi
