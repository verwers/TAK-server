#!/usr/bin/env bash
# init-config.sh
# CoreConfig initialization for TAK Server.
# Sets up CoreConfig.xml from the example and injects database credentials.

set -euo pipefail

# Source environment setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./init-env.sh
source "${SCRIPT_DIR}/init-env.sh"

# ============================================================================
# CoreConfig Initialization
# ============================================================================

setup_coreconfig() {
  log_info "Setting up CoreConfig..."
  
  # Bootstrap CoreConfig from example on first boot
  if [[ ! -f "${CORE_CFG}" ]]; then
    log_info "Bootstrapping CoreConfig from example"
    cp "${CORE_EXAMPLE}" "${CORE_CFG}" || {
      log_error "Failed to copy CoreConfig.example.xml to CoreConfig.xml"
      return 1
    }
  else
    log_info "CoreConfig already exists, skipping bootstrap"
  fi
  
  # Inject database password into CoreConfig
  # The Dockerfile no longer bakes a password into the image
  log_info "Injecting database password into CoreConfig"
  
  # Escape forward slashes and backslashes in password for sed
  escaped_pw="${TAK_DB_PASSWORD//\\/\\\\}"
  escaped_pw="${escaped_pw//\//\\/}"
  
  if sed -i -E "s/password=\"[^\"]*\"/password=\"${escaped_pw}\"/g" "${CORE_CFG}"; then
    log_info "Database password injected successfully"
  else
    log_error "Failed to inject database password into CoreConfig"
    return 1
  fi
  
  return 0
}

# ============================================================================
# Certificate Metadata Configuration
# ============================================================================

setup_cert_metadata() {
  log_info "Configuring certificate metadata..."
  
  if [[ -f "${CERT_DIR}/cert-metadata.sh" ]]; then
    log_info "Updating cert-metadata.sh with environment values"
    
    if sed -i \
      -e "s/^COUNTRY=.*/COUNTRY=${COUNTRY}/" \
      -e "s/^STATE=.*/STATE=${STATE}/" \
      -e "s/^CITY=.*/CITY=${CITY}/" \
      -e "s/^ORGANIZATION=.*/ORGANIZATION=${ORGANIZATION}/" \
      -e "s/^ORGANIZATIONAL_UNIT=.*/ORGANIZATIONAL_UNIT=${ORGANIZATIONAL_UNIT}/" \
      "${CERT_DIR}/cert-metadata.sh"; then
      log_info "Certificate metadata configured"
    else
      log_warn "Failed to update cert-metadata.sh (may not exist yet)"
    fi
  else
    log_warn "cert-metadata.sh not found; using defaults for certificate generation"
  fi
  
  return 0
}

# ============================================================================
# Initialization Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  log_info "TAK Server CoreConfig initialization"
  
  if ! setup_coreconfig; then
    log_error "CoreConfig setup failed"
    exit 1
  fi
  
  if ! setup_cert_metadata; then
    log_warn "Certificate metadata setup had issues but continuing"
  fi
  
  log_info "CoreConfig initialization complete"
fi
