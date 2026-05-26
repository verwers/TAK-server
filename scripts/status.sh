#!/usr/bin/env bash
# status.sh
# TAK Server deployment health check and status report.
# Provides information about server health, connected clients, and certificate expiry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_info() { echo "ℹ $1"; }
log_section() { echo -e "${BLUE}═══ $1 ═══${NC}"; }

# ============================================================================
# Container Detection
# ============================================================================

container_is_running() {
  local container_name="$1"
  docker ps --filter "name=$container_name" --format "{{.Names}}" | grep -q "^${container_name}$" 2>/dev/null || return 1
}

get_container_id() {
  local container_name="$1"
  docker ps -q -f "name=$container_name" 2>/dev/null | head -1
}

# ============================================================================
# Health Checks
# ============================================================================

check_containers() {
  log_section "Container Status"
  
  for container in "takserver-db" "takserver"; do
    if container_is_running "$container"; then
      log_pass "$container is running"
    else
      log_fail "$container is not running"
    fi
  done
  echo ""
}

check_ports() {
  log_section "Port Availability"
  
  declare -A PORTS=(
    [8089]="CoT streaming (ATAK)"
    [8443]="Marti / Web UI"
    [8444]="Federation"
    [8446]="Cert enrollment"
    [9000]="Federation v2"
    [9001]="Federation v2 (alt)"
  )
  
  for port in "${!PORTS[@]}"; do
    if nc -z localhost "$port" &>/dev/null; then
      log_pass "Port $port listening (${PORTS[$port]})"
    else
      log_warn "Port $port not listening (${PORTS[$port]})"
    fi
  done
  echo ""
}

check_database() {
  log_section "Database Status"
  
  if takserver_id=$(get_container_id "takserver"); then
    if docker exec "$takserver_id" pg_isready -h tak-database -U postgres &>/dev/null; then
      log_pass "PostgreSQL is responsive"
      
      # Get database size
      if db_size=$(docker exec "$takserver_id" psql -U postgres -d cot -t -c "SELECT pg_size_pretty(pg_database_size('cot'))" 2>/dev/null); then
        log_info "Database size: $db_size"
      fi
    else
      log_fail "PostgreSQL not responding"
    fi
  else
    log_fail "TAK Server container not found"
  fi
  echo ""
}

check_certificates() {
  log_section "Certificate Status"
  
  CERTS_DIR="${PROJECT_ROOT}/data/certs"
  
  if [[ ! -d "$CERTS_DIR" ]]; then
    log_warn "Certificates directory not found"
    echo ""
    return
  fi
  
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
    log_warn "CA certificate not found"
  fi
  
  # Count certificates (.p12 keystores + .pem certs)
  cert_count=$(find "$CERTS_DIR" -maxdepth 1 -type f \( -name "*.p12" -o -name "*.pem" \) 2>/dev/null | wc -l)
  log_info "Certificates: $cert_count files"
  
  # Count data packages
  dp_count=$(find "$CERTS_DIR" -maxdepth 1 -name "*.dp.zip" -type f 2>/dev/null | wc -l)
  log_info "Data Packages: $dp_count files"
  
  echo ""
}

check_tak_server_logs() {
  log_section "TAK Server Status"
  
  if takserver_id=$(get_container_id "takserver"); then
    # Check for startup completion
    if docker logs "$takserver_id" 2>&1 | grep -qi "listening on port 8089\|TAK Server started" &>/dev/null; then
      log_pass "TAK Server appears to be running"
    elif docker logs "$takserver_id" 2>&1 | grep -qi "error\|exception" &>/dev/null; then
      log_fail "TAK Server has errors (check logs)"
    else
      log_warn "TAK Server status unclear (may still be starting)"
    fi
    
    # Show recent errors if any
    if errors=$(docker logs "$takserver_id" 2>&1 | grep -i "error" | tail -1); then
      if [[ -n "$errors" ]]; then
        log_warn "Recent error: ${errors:0:80}..."
      fi
    fi
  else
    log_fail "TAK Server container not found"
  fi
  echo ""
}

check_initialization_log() {
  log_section "Initialization Log"
  
  if takserver_id=$(get_container_id "takserver"); then
    if docker exec "$takserver_id" test -f /opt/tak/logs/init.log 2>/dev/null; then
      # Show last 5 lines of init log
      echo "Last initialization entries:"
      docker exec "$takserver_id" tail -5 /opt/tak/logs/init.log 2>/dev/null | sed 's/^/  /'
    else
      log_warn "Initialization log not found"
    fi
  fi
  echo ""
}

# ============================================================================
# Summary Report
# ============================================================================

show_summary() {
  echo ""
  log_section "Deployment Status Summary"
  
  local passed=0
  local failed=0
  local warnings=0
  
  # Count results (simplified check)
  if container_is_running "takserver" && container_is_running "takserver-db"; then
    ((passed++))
  else
    ((failed++))
  fi
  
  if nc -z localhost 8089 &>/dev/null; then
    ((passed++))
  else
    ((failed++))
  fi
  
  if [[ -f "${PROJECT_ROOT}/data/certs/files/ca.pem" ]]; then
    ((passed++))
  else
    ((failed++))
  fi
  
  echo ""
  echo "Overall: ${passed} healthy, ${failed} issues"
  
  if [[ $failed -eq 0 ]]; then
    log_pass "Deployment appears healthy"
  else
    log_warn "Deployment has issues; review above for details"
  fi
  
  echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}TAK Server Deployment Status${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo ""
  
  check_containers
  check_ports
  check_database
  check_certificates
  check_tak_server_logs
  check_initialization_log
  show_summary
}

main "$@"
