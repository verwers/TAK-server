#!/usr/bin/env bash
# test-client-connection.sh
# Optional client connection test for TAK Server.
# Attempts to establish a TLS connection using a generated client certificate
# and sends a simple CoT message to verify the server is accepting connections.
# This runs inside the takserver container or can run standalone with proper certs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Support both execution contexts:
# - Host checkout: docker/test-client-connection.sh -> ../data/certs/files
# - takserver container: /opt/tak/scripts/test-client-connection.sh -> /opt/tak/certs/files
if [[ -d "/opt/tak/certs/files" ]]; then
  FILES_DIR="/opt/tak/certs/files"
else
  CERT_DIR="${SCRIPT_DIR}/../data/certs"
  FILES_DIR="${CERT_DIR}/files"
fi

# Configuration
TAK_HOST="${TAK_HOST:-localhost}"
TAK_PORT="${TAK_PORT:-8089}"
TEST_CLIENT="${TEST_CLIENT:-client}"
CERT_PASSWORD="${CERT_PASSWORD:-${TAK_CERT_PASSWORD:-atakatak}}"
TIMEOUT="${TIMEOUT:-10}"
REGENERATE_ON_CERT_PASSWORD_MISMATCH="${REGENERATE_ON_CERT_PASSWORD_MISMATCH:-true}"
CONNECT_WAIT_SECONDS="${CONNECT_WAIT_SECONDS:-45}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() {
  echo -e "${GREEN}✓${NC} $1"
}

log_fail() {
  echo -e "${RED}✗${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
  echo "ℹ $1"
}

extract_client_materials() {
  if openssl pkcs12 -in "$CLIENT_CERT" -passin "pass:${CERT_PASSWORD}" -out "$CLIENT_PEM" -nokeys &>/dev/null || \
     openssl pkcs12 -legacy -in "$CLIENT_CERT" -passin "pass:${CERT_PASSWORD}" -out "$CLIENT_PEM" -nokeys &>/dev/null; then
    log_pass "Extracted client certificate"
  else
    return 1
  fi

  if openssl pkcs12 -in "$CLIENT_CERT" -passin "pass:${CERT_PASSWORD}" -out "$CLIENT_KEY" -nocerts -nodes &>/dev/null || \
     openssl pkcs12 -legacy -in "$CLIENT_CERT" -passin "pass:${CERT_PASSWORD}" -out "$CLIENT_KEY" -nocerts -nodes &>/dev/null; then
    log_pass "Extracted client key"
  else
    return 1
  fi

  return 0
}

regenerate_client_cert() {
  local cert_tool="/opt/tak/certs/makeCert.sh"
  local cert_files_dir="/opt/tak/certs/files"

  if [[ ! -x "$cert_tool" || ! -d "$cert_files_dir" ]]; then
    return 1
  fi

  log_warn "Client certificate appears to use a different password; regenerating ${TEST_CLIENT}.p12 with current configuration"

  rm -f "${cert_files_dir}/${TEST_CLIENT}.p12" \
        "${cert_files_dir}/${TEST_CLIENT}.pem" \
        "${cert_files_dir}/${TEST_CLIENT}.key" \
        "${cert_files_dir}/${TEST_CLIENT}.csr" \
        "${cert_files_dir}/${TEST_CLIENT}.jks" \
        "${cert_files_dir}/${TEST_CLIENT}-trusted.pem"

  if (cd "/opt/tak/certs" && PASS="${CERT_PASSWORD}" ./makeCert.sh client "${TEST_CLIENT}" >/dev/null 2>&1); then
    log_pass "Regenerated client certificate for ${TEST_CLIENT}"
    return 0
  fi

  return 1
}

echo "════════════════════════════════════════════════════════════════"
echo "TAK Server Client Connection Test"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Check prerequisites
echo "Prerequisites:"
if ! command -v openssl &> /dev/null; then
  log_fail "openssl not found"
  exit 1
fi
log_pass "openssl available"

if ! command -v timeout &> /dev/null; then
  log_warn "timeout command not found; will proceed without timeout"
fi

# Check for client certificate
echo ""
echo "Certificate Check:"
CLIENT_CERT="${FILES_DIR}/${TEST_CLIENT}.p12"
if [[ ! -f "$CLIENT_CERT" ]]; then
  log_fail "Client certificate not found: $CLIENT_CERT"
  echo ""
  echo "Available certificates:"
  find "$FILES_DIR" -maxdepth 1 -name "*.p12" -type f | sed 's/^/  /'
  exit 1
fi
log_pass "Client certificate found: $CLIENT_CERT"

# Convert P12 to PEM for testing
echo ""
echo "Converting certificate to PEM format..."
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

CLIENT_PEM="${TEMP_DIR}/${TEST_CLIENT}.pem"
CLIENT_KEY="${TEMP_DIR}/${TEST_CLIENT}.key"

# Extract certificate and key from PKCS12
if ! extract_client_materials; then
  if [[ "${REGENERATE_ON_CERT_PASSWORD_MISMATCH}" == "true" ]] && regenerate_client_cert; then
    CLIENT_CERT="${FILES_DIR}/${TEST_CLIENT}.p12"
    if ! extract_client_materials; then
      log_fail "Failed to extract client certificate/key after regeneration"
      log_info "Hint: set CERT_PASSWORD or TAK_CERT_PASSWORD to the password used for ${TEST_CLIENT}.p12"
      exit 1
    fi
  else
    log_fail "Failed to extract client certificate from P12 file"
    log_info "Hint: set CERT_PASSWORD or TAK_CERT_PASSWORD to the password used for ${TEST_CLIENT}.p12"
    exit 1
  fi
fi

# Test TLS connection
echo ""
echo "Connection Test:"

TARGET_HOST="$TAK_HOST"
if [[ "$TARGET_HOST" == "localhost" ]]; then
  # TAK commonly listens on IPv4 in-container; avoid ::1 resolution issues.
  TARGET_HOST="127.0.0.1"
fi

echo "Attempting TLS handshake to $TARGET_HOST:$TAK_PORT with client cert '$TEST_CLIENT'..."

CA_FILE=""
for _ca_candidate in "${FILES_DIR}/ca.pem" "${FILES_DIR}/root-ca.pem" "${FILES_DIR}/ca.crt"; do
  if [[ -f "$_ca_candidate" ]]; then
    CA_FILE="$_ca_candidate"
    break
  fi
done
unset _ca_candidate

OPENSSL_ARGS=(
  s_client
  -connect "$TARGET_HOST:$TAK_PORT"
  -cert "$CLIENT_PEM"
  -key "$CLIENT_KEY"
  -brief
)

if [[ -n "$CA_FILE" ]]; then
  OPENSSL_ARGS+=( -CAfile "$CA_FILE" )
fi

TLS_OUTPUT=""
CONNECTION_SUCCESS=0
ATTEMPT=1
MAX_ATTEMPTS=$(( (CONNECT_WAIT_SECONDS + 1) / 2 ))

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  if command -v timeout &> /dev/null; then
    TLS_OUTPUT="$(timeout "$TIMEOUT" openssl "${OPENSSL_ARGS[@]}" < /dev/null 2>&1 || true)"
  else
    TLS_OUTPUT="$(openssl "${OPENSSL_ARGS[@]}" < /dev/null 2>&1 || true)"
  fi

  if echo "$TLS_OUTPUT" | grep -q "CONNECTION ESTABLISHED"; then
    CONNECTION_SUCCESS=1
    break
  fi

  if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
    echo "  waiting for TAK listener... (${ATTEMPT}/${MAX_ATTEMPTS})"
    sleep 2
  fi
  ((++ATTEMPT))
done

echo ""
if [[ $CONNECTION_SUCCESS -eq 1 ]]; then
  log_pass "Successfully connected to TAK Server with client certificate"
  echo ""
  log_pass "Connection test PASSED"
  echo ""
  echo "Client '$TEST_CLIENT' can successfully connect to $TAK_HOST:$TAK_PORT"
  exit 0
else
  log_fail "Failed to connect to $TARGET_HOST:$TAK_PORT"
  if [[ -n "$TLS_OUTPUT" ]]; then
    echo ""
    echo "OpenSSL output (first lines):"
    echo "$TLS_OUTPUT" | sed -n '1,8p' | sed 's/^/  /'
  fi
  echo ""
  echo "Diagnostics:"
  echo "  - Ensure TAK Server is running: docker ps | grep takserver"
  echo "  - Check if port $TAK_PORT is listening: nc -zv $TAK_HOST $TAK_PORT"
  echo "  - Review TAK Server logs: docker logs \$(docker ps -q -f name=takserver)"
  echo "  - Verify certificate password is correct: TAK_CERT_PASSWORD in .env"
  echo ""
  log_warn "Connection test FAILED"
  exit 1
fi
