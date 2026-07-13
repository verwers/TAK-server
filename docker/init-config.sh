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
  
  # Escape characters that are special on the sed replacement side:
  #   \  - literal backslash
  #   &  - matched text
  #   |  - our chosen delimiter
  escaped_pw="${TAK_DB_PASSWORD//\\/\\\\}"
  escaped_pw="${escaped_pw//&/\\&}"
  escaped_pw="${escaped_pw//|/\\|}"
  
  # Only update the password on the <connection ...> element inside <repository>;
  # using `g` with a broad pattern would clobber every password attribute in the
  # file (keystore, federation, ...).
  if sed -i -E "s|(<connection[^>]*password=\")[^\"]*(\")|\1${escaped_pw}\2|" "${CORE_CFG}"; then
    log_info "Database password injected successfully"
  else
    log_error "Failed to inject database password into CoreConfig"
    return 1
  fi

  # Fix server URLs to use the canonical hostname instead of the ephemeral
  # container IP that TAK auto-discovers on first startup.
  fix_server_urls

  # Allow non-admin users to log into the web UI on 8443.
  enable_non_admin_ui

  return 0
}

# ----------------------------------------------------------------------------
# fix_server_urls
# Ensures <urladd> and federation webBaseUrl reference CANONICAL_HOST, not the
# ephemeral Docker-assigned container IP.
#
# TAK's Spring application writes these elements into CoreConfig.xml on its
# first startup (after init scripts have already run).  We therefore handle
# two cases on every boot:
#
#   a) Element absent  → insert it now so TAK sees a correct value on first
#                        start and (hopefully) leaves it alone.
#   b) Element present → update it so any container-IP value left by a
#                        previous TAK run is replaced with CANONICAL_HOST.
# ----------------------------------------------------------------------------
fix_server_urls() {
  # SERVER_ADDRESS overrides the auto-detected CANONICAL_HOST so operators can
  # set the externally-reachable address independently of the certificate SANs.
  local server_addr="${SERVER_ADDRESS:-${CANONICAL_HOST}}"
  local base_url="https://${server_addr}:8443"
  log_info "Fixing server URLs to ${base_url} (SERVER_ADDRESS=${SERVER_ADDRESS:-<unset>}, CANONICAL_HOST=${CANONICAL_HOST})"

  # --- <urladd> in <filter> ---
  # TAK embeds this URL in outbound CoT events so clients know where to
  # download map tiles and other content.  The auto-detected value uses the
  # container's internal IP on port 8080 (HTTP, not exposed in Compose).
  if grep -q '<urladd' "${CORE_CFG}"; then
    sed -i -E "s|(<urladd[^>]*host=\")[^\"]*\"|\1${base_url}\"|" "${CORE_CFG}" \
      && log_info "Updated <urladd> host to ${base_url}" \
      || log_warn "sed update of <urladd> failed"
  else
    # Pre-insert before <flowtag> (always present in the example).  TAK will
    # see the element already present on its first start and skip auto-adding
    # it with the wrong container IP.
    sed -i "s|<flowtag |<thumbnail/>\n        <urladd host=\"${base_url}\"/>\n        <flowtag |" "${CORE_CFG}" \
      && log_info "Inserted <urladd> with host ${base_url}" \
      || log_warn "Failed to insert <urladd> (flowtag anchor not found in CoreConfig)"
  fi

  # --- webBaseUrl in <federation-server> ---
  # TAK writes this block on its first startup (after init scripts run), so it
  # can only be updated from the second boot onward.  That is acceptable: the
  # container IP it initially writes still works on the internal Docker network;
  # the corrected hostname takes effect from the next restart.
  if grep -q 'webBaseUrl' "${CORE_CFG}"; then
    sed -i -E "s|(webBaseUrl=\")[^\"]*\"|\1${base_url}/Marti\"|" "${CORE_CFG}" \
      && log_info "Updated federation webBaseUrl to ${base_url}/Marti" \
      || log_warn "sed update of webBaseUrl failed"
  else
    log_info "No webBaseUrl found yet; federation URL will be corrected on next restart"
  fi
}

# ----------------------------------------------------------------------------
# enable_non_admin_ui
# Sets enableNonAdminUI="true" on the 8443 connector so non-admin users can
# log into the web UI. Idempotent and safe to re-run.
# ----------------------------------------------------------------------------
enable_non_admin_ui() {
  if grep -q '<connector[^>]*port="8443"[^>]*enableNonAdminUI=' "${CORE_CFG}"; then
    sed -i -E "s|(<connector[^>]*port=\"8443\"[^>]*enableNonAdminUI=\")[^\"]*\"|\1true\"|" "${CORE_CFG}" \
      && log_info "Set 8443 connector enableNonAdminUI=true" \
      || log_warn "Failed to update enableNonAdminUI on 8443 connector"
  elif grep -q '<connector[^>]*port="8443"' "${CORE_CFG}"; then
    sed -i -E "s|(<connector[^>]*port=\"8443\"[^/]*)/>|\1 enableNonAdminUI=\"true\"/>|" "${CORE_CFG}" \
      && log_info "Added enableNonAdminUI=true to 8443 connector" \
      || log_warn "Failed to add enableNonAdminUI to 8443 connector"
  else
    log_warn "No 8443 connector found; skipping enableNonAdminUI"
  fi
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
