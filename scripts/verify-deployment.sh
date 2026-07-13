#!/usr/bin/env bash
# verify-deployment.sh
# Post-deployment validation for TAK Server Docker setup.
# Verifies ports are listening, certs are valid, database is healthy, and data packages exist.
# Exit code: 0 = all checks passed, 1 = one or more failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERTS_DIR="${PROJECT_ROOT}/data/certs"
DOCKER_COMPOSE="${PROJECT_ROOT}/docker-compose.yml"

# Load .env so checks use the configured Postgres credentials/db name.
# shellcheck disable=SC1091
[[ -f "${PROJECT_ROOT}/.env" ]] && source "${PROJECT_ROOT}/.env"
PG_USER="${POSTGRES_USER:-martiuser}"
PG_DB="${POSTGRES_DB:-cot}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CHECKS_PASSED=0
CHECKS_FAILED=0

log_pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((++CHECKS_PASSED))
}

log_fail() {
  echo -e "${RED}✗${NC} $1"
  ((++CHECKS_FAILED))
}

log_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
  echo "ℹ $1"
}

# Detect container status
container_is_running() {
  local container_name="$1"
  docker ps --filter "name=$container_name" --format "{{.Names}}" | grep -q "^${container_name}$" 2>/dev/null || return 1
}

get_container_id() {
  local container_name="$1"
  docker ps -q -f "name=$container_name" 2>/dev/null | head -1
}

echo "════════════════════════════════════════════════════════════════"
echo "TAK Server Deployment Verification"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Check 1: Docker Compose file exists
if [[ -f "$DOCKER_COMPOSE" ]]; then
  log_pass "docker-compose.yml found"
else
  log_fail "docker-compose.yml not found at $DOCKER_COMPOSE"
  exit 1
fi

# Check 2: Containers are running
echo ""
echo "Container Status:"
for container in "takserver-db" "takserver"; do
  if container_is_running "$container"; then
    log_pass "Container '$container' is running"
  else
    log_fail "Container '$container' is not running"
  fi
done

# Check 3: Ports are listening
echo ""
echo "Port Availability:"
declare -A PORTS=(
  [8089]="CoT streaming (ATAK clients)"
  [8443]="Marti / Web UI"
  [8444]="Federation (TLS)"
  [8446]="Certificate enrollment"
  [9000]="Federation v2"
  [9001]="Federation v2 (alt)"
)

for port in "${!PORTS[@]}"; do
  if nc -z localhost "$port" &>/dev/null; then
    log_pass "Port $port listening (${PORTS[$port]})"
  else
    log_fail "Port $port not listening (${PORTS[$port]})"
  fi
done

# Check 4: Database health
echo ""
echo "Database Health:"
if takserver_id=$(get_container_id "takserver"); then
  if docker exec "$takserver_id" pg_isready -h tak-database -U "$PG_USER" -d "$PG_DB" &>/dev/null; then
    log_pass "PostgreSQL is responsive on internal network"
  else
    log_fail "PostgreSQL not responding (may still be starting)"
  fi
else
  log_warn "TAK Server container not found; skipping database check"
fi

# Check 5: Certificate files
echo ""
echo "Certificate Files:"
if [[ -d "$CERTS_DIR" ]]; then
  log_pass "Certificates directory exists: $CERTS_DIR"
  
  # List cert files
  cert_count=0
  while IFS= read -r cert_file; do
    cert_count=$((cert_count + 1))
  done < <(find "$CERTS_DIR" -maxdepth 1 -type f \( -name "*.p12" -o -name "*.pem" \))
  
  if [[ $cert_count -gt 0 ]]; then
    log_pass "Found $cert_count certificate files"
  else
    log_fail "No certificate files found in $CERTS_DIR"
  fi
else
  log_fail "Certificates directory not found at $CERTS_DIR"
fi

# Check 6: Data Packages
echo ""
echo "Data Packages:"
if [[ -d "$CERTS_DIR" ]]; then
  dp_count=0
  declare -a dp_files
  while IFS= read -r dp_file; do
    dp_count=$((dp_count + 1))
    dp_files+=("$(basename "$dp_file")")
  done < <(find "$CERTS_DIR" -maxdepth 1 -name "*.dp.zip" -type f)
  
  if [[ $dp_count -gt 0 ]]; then
    log_pass "Found $dp_count Data Package(s)"
    for dp in "${dp_files[@]}"; do
      log_info "  - $dp"
    done
  else
    log_warn "No Data Packages found (may still be generating on first boot)"
  fi
else
  log_warn "Certificates directory not accessible; cannot check Data Packages"
fi

# Check 7: Certificate validity (if certs exist)
echo ""
echo "Certificate Validity:"
# Try multiple candidate locations for the CA certificate
ca_cert=""
for candidate in \
  "$CERTS_DIR/files/ca.pem" \
  "$CERTS_DIR/files/root-ca.pem" \
  "$CERTS_DIR/files/ca.crt" \
  "$CERTS_DIR/ca.pem" \
  "$CERTS_DIR/root-ca.pem" \
  "$CERTS_DIR/ca.crt"; do
  if [[ -f "$candidate" ]]; then
    ca_cert="$candidate"
    break
  fi
done
if [[ -n "$ca_cert" ]]; then
  # Extract expiry date
  exp_date=$(openssl x509 -in "$ca_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
  exp_epoch=$(date -d "$exp_date" +%s 2>/dev/null || echo 0)
  current_epoch=$(date +%s)
  days_remaining=$(( (exp_epoch - current_epoch) / 86400 ))
  
  if [[ $days_remaining -gt 30 ]]; then
    log_pass "CA certificate valid ($days_remaining days remaining)"
  elif [[ $days_remaining -gt 0 ]]; then
    log_warn "CA certificate expiring soon ($days_remaining days remaining)"
  else
    log_fail "CA certificate expired"
  fi
else
  log_warn "CA certificate not found; skipping validity check"
fi

# Check 8: TAK Server logs for errors
echo ""
echo "TAK Server Startup:"
if takserver_id=$(get_container_id "takserver"); then
  # Look for errors in recent logs
  if docker logs "$takserver_id" 2>&1 | grep -i "error\|failed\|exception" | head -3 > /tmp/tak_errors.txt 2>&1; then
    if [[ -s /tmp/tak_errors.txt ]]; then
      log_fail "Found errors in TAK Server logs:"
      while IFS= read -r line; do
        log_info "  $line"
      done < /tmp/tak_errors.txt
    else
      log_pass "No errors detected in TAK Server logs"
    fi
  else
    log_pass "No errors detected in TAK Server logs"
  fi
  
  # Check if TAK Server is fully started
  if docker logs "$takserver_id" 2>&1 | grep -q "TAK Server started\|listening on port 8089\|Marti started" 2>/dev/null; then
    log_pass "TAK Server appears to be fully started"
  else
    log_warn "TAK Server startup may still be in progress"
  fi
else
  log_warn "TAK Server container not found; cannot check logs"
fi

# Summary
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Verification Summary"
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}Passed:${NC} $CHECKS_PASSED"
echo -e "${RED}Failed:${NC} $CHECKS_FAILED"
echo ""

if [[ $CHECKS_FAILED -eq 0 ]]; then
  echo -e "${GREEN}✓ All checks passed! Deployment appears healthy.${NC}"
  echo ""
  echo "Next steps:"
  echo "  1. Download a .dp.zip Data Package from: $CERTS_DIR/"
  echo "  2. Import it into ATAK on a client device"
  echo "  3. Attempt to connect to the server"
  echo ""
  exit 0
else
  echo -e "${RED}✗ Some checks failed. Review output above for details.${NC}"
  echo ""
  echo "Troubleshooting:"
  echo "  - Check if containers are still starting: docker compose logs -f"
  echo "  - Verify .env configuration: cat ${PROJECT_ROOT}/.env"
  echo "  - Check TAK Server logs: docker logs \$(docker ps -q -f name=takserver)"
  echo ""
  exit 1
fi
