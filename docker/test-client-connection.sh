#!/usr/bin/env bash
# test-client-connection.sh
# Optional client connection test for TAK Server.
# Attempts to establish a TLS connection using a generated client certificate
# and sends a simple CoT message to verify the server is accepting connections.
# This runs inside the takserver container or can run standalone with proper certs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/../data/certs"
FILES_DIR="${CERT_DIR}/files"

# Configuration
TAK_HOST="${TAK_HOST:-localhost}"
TAK_PORT="${TAK_PORT:-8089}"
TEST_CLIENT="${TEST_CLIENT:-client}"
CERT_PASSWORD="${CERT_PASSWORD:-atakatak}"
TIMEOUT="${TIMEOUT:-10}"

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
if openssl pkcs12 -in "$CLIENT_CERT" -passin "pass:${CERT_PASSWORD}" -out "$CLIENT_PEM" -nokeys &>/dev/null; then
  log_pass "Extracted client certificate"
else
  log_fail "Failed to extract client certificate from P12 file"
  exit 1
fi

if openssl pkcs12 -in "$CLIENT_CERT" -passin "pass:${CERT_PASSWORD}" -out "$CLIENT_KEY" -nocerts -nodes &>/dev/null; then
  log_pass "Extracted client key"
else
  log_fail "Failed to extract client key from P12 file"
  exit 1
fi

# Test TLS connection
echo ""
echo "Connection Test:"
echo "Attempting TLS connection to $TAK_HOST:$TAK_PORT with client cert '$TEST_CLIENT'..."

# Create a simple CoT message (minimal XML)
# This is a bare-minimum valid CoT event for testing
COT_MESSAGE='<?xml version="1.0" encoding="UTF-8"?>
<event version="2.0" uid="test-client-'$(date +%s)'" type="a-h-G-E-S" time="'$(date -u +%Y-%m-%dT%H:%M:%SZ)'" start="'$(date -u +%Y-%m-%dT%H:%M:%SZ)'" stale="'$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)'">
  <point lat="0.0" lon="0.0" hae="0.0" ce="9999999.0" le="9999999.0"/>
  <detail>
    <contact callsign="TestClient"/>
  </detail>
</event>'

# Attempt connection with timeout
CONNECTION_SUCCESS=0
if command -v timeout &> /dev/null; then
  if (timeout "$TIMEOUT" bash -c "echo '$COT_MESSAGE' | openssl s_client -connect '$TAK_HOST:$TAK_PORT' -cert '$CLIENT_PEM' -key '$CLIENT_KEY' -quiet 2>/dev/null" &>/dev/null); then
    CONNECTION_SUCCESS=1
  fi
else
  # Fallback without timeout (may hang if server is unresponsive)
  if (echo "$COT_MESSAGE" | openssl s_client -connect "$TAK_HOST:$TAK_PORT" -cert "$CLIENT_PEM" -key "$CLIENT_KEY" -quiet 2>/dev/null) &>/dev/null; then
    CONNECTION_SUCCESS=1
  fi
fi

echo ""
if [[ $CONNECTION_SUCCESS -eq 1 ]]; then
  log_pass "Successfully connected to TAK Server with client certificate"
  echo ""
  log_pass "Connection test PASSED"
  echo ""
  echo "Client '$TEST_CLIENT' can successfully connect to $TAK_HOST:$TAK_PORT"
  exit 0
else
  log_fail "Failed to connect to $TAK_HOST:$TAK_PORT"
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
