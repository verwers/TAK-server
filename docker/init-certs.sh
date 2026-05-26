#!/usr/bin/env bash
# init-certs.sh
# Certificate generation for TAK Server.
# Creates root CA, server certificate with SANs, and client certificates.

set -euo pipefail

# Source environment setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./init-env.sh
source "${SCRIPT_DIR}/init-env.sh"

# ============================================================================
# Certificate Generation Functions
# ============================================================================

ensure_root_ca() {
  log_info "Checking for root CA..."
  
  if [[ -f "${FILES_DIR}/ca.pem" || -f "${FILES_DIR}/root-ca.pem" ]]; then
    log_info "Root CA already exists, skipping generation"
    return 0
  fi
  
  log_info "Generating root CA '${CA_NAME}'"
  
  # Export password for makeRootCa.sh
  export CAPASS="${TAK_CERT_PASSWORD}"
  
  if (cd "${CERT_DIR}" && ./makeRootCa.sh --ca-name "${CA_NAME}"); then
    log_info "Root CA generated successfully"
    return 0
  else
    log_error "Failed to generate root CA"
    return 1
  fi
}

ensure_server_cert() {
  log_info "Checking for server certificate..."
  
  if [[ -f "${FILES_DIR}/${CANONICAL_HOST}.p12" ]]; then
    log_info "Server certificate already exists for ${CANONICAL_HOST}, skipping generation"
    return 0
  fi
  
  log_info "Generating server certificate for ${CANONICAL_HOST}"
  
  if [[ ${#HOSTS[@]} -gt 1 ]]; then
    log_info "  SANs: ${HOSTS[*]:1}"
  fi
  
  # Export password for makeCert.sh
  export PASS="${TAK_CERT_PASSWORD}"
  
  local -a sans=()
  local h
  for h in "${HOSTS[@]:1}"; do
    sans+=("$h")
  done
  
  if (cd "${CERT_DIR}" && ./makeCert.sh server "${CANONICAL_HOST}" "${sans[@]}"); then
    log_info "Server certificate generated successfully"
    return 0
  else
    log_error "Failed to generate server certificate"
    return 1
  fi
}

ensure_client_cert() {
  local name="$1"
  
  if [[ -f "${FILES_DIR}/${name}.p12" ]]; then
    log_debug "Client certificate already exists for ${name}, skipping"
    return 0
  fi
  
  log_info "Generating client certificate for ${name}"
  
  # Export password for makeCert.sh
  export PASS="${TAK_CERT_PASSWORD}"
  
  if (cd "${CERT_DIR}" && ./makeCert.sh client "${name}"); then
    log_info "Client certificate generated for ${name}"
    return 0
  else
    log_error "Failed to generate client certificate for ${name}"
    return 1
  fi
}

# ============================================================================
# Main Initialization
# ============================================================================

initialize_certificates() {
  log_info "TAK Server certificate initialization"
  
  # Parse hosts and users if not already done
  if [[ -z "${HOSTS:-}" ]]; then
    parse_hosts_and_users || return 1
  fi
  
  # Generate root CA
  if ! ensure_root_ca; then
    log_error "Root CA generation failed"
    return 1
  fi
  
  # Generate server certificate
  if ! ensure_server_cert; then
    log_error "Server certificate generation failed"
    return 1
  fi
  
  # Generate admin certificate
  if ! ensure_client_cert "admin"; then
    log_error "Admin certificate generation failed"
    return 1
  fi
  
  # Generate client certificates
  local failed=0
  for u in "${USERS[@]}"; do
    if ! ensure_client_cert "$u"; then
      log_error "Failed to generate certificate for user: $u"
      ((failed++))
    fi
  done
  
  if [[ $failed -gt 0 ]]; then
    log_warn "Certificate generation completed with $failed error(s)"
    return 1
  fi
  
  log_info "All certificates generated successfully"
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
  
  # Initialize certificates
  if ! initialize_certificates; then
    log_error "Certificate initialization failed"
    exit 1
  fi
  
  log_info "Certificate initialization complete"
fi
