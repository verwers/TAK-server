#!/usr/bin/env bash
# init-datapackages.sh
# Data package generation for TAK Server.
# Creates .dp.zip files for each user, optionally per-host.

set -euo pipefail

# Source environment setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./init-env.sh
source "${SCRIPT_DIR}/init-env.sh"

# ============================================================================
# Data Package Creation
# ============================================================================

create_datapackage() {
  local user="$1"
  local host="$2"
  local out="${FILES_DIR}/${user}-${host}.dp.zip"
  
  if [[ -f "$out" ]]; then
    log_debug "Data package already exists for ${user}@${host}"
    return 0
  fi
  
  log_info "Creating Data Package for ${user}@${host}"
  
  # Export variables for certDP.sh
  export TAK_CERT_DIR="${FILES_DIR}"
  export TAK_CERT_PASSWORD="${TAK_CERT_PASSWORD}"
  
  if /opt/tak/scripts/certDP.sh "${user}" "${host}"; then
    log_info "Data Package created for ${user}@${host}"
    return 0
  else
    log_error "Failed to create Data Package for ${user}@${host}"
    return 1
  fi
}

# ============================================================================
# Main Initialization
# ============================================================================

initialize_datapackages() {
  log_info "TAK Server Data Package initialization"
  
  # Parse hosts and users if not already done
  if [[ -z "${HOSTS:-}" ]]; then
    parse_hosts_and_users || return 1
  fi
  
  local total_dps=0
  local failed_dps=0
  
  # Create data packages per user
  if [[ "${MULTI_HOST_DP}" == "true" ]]; then
    log_info "Multi-host Data Packages enabled (one per user, per host)"
    for u in "${USERS[@]}"; do
      for h in "${HOSTS[@]}"; do
        ((total_dps++))
        if ! create_datapackage "$u" "$h"; then
          ((failed_dps++))
        fi
      done
    done
  else
    log_info "Single-host Data Packages (one per user for canonical host)"
    for u in "${USERS[@]}"; do
      ((total_dps++))
      if ! create_datapackage "$u" "${CANONICAL_HOST}"; then
        ((failed_dps++))
      fi
    done
  fi
  
  log_info "Data Package creation: $((total_dps - failed_dps))/$total_dps successful"
  
  if [[ $failed_dps -gt 0 ]]; then
    log_warn "Data Package creation completed with $failed_dps error(s)"
    # Don't fail here; DPs can be regenerated later if needed
  fi
  
  return 0
}

# ============================================================================
# Initialization Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Validate environment first
  if ! validate_environment; then
    log_error "Environment validation failed"
    exit 1
  fi
  
  # Parse hosts and users
  if ! parse_hosts_and_users; then
    log_error "Failed to parse hosts and users"
    exit 1
  fi
  
  # Initialize data packages
  if ! initialize_datapackages; then
    log_error "Data package initialization had errors"
    exit 1
  fi
  
  log_info "Data package initialization complete"
fi
