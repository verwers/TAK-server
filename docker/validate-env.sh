#!/usr/bin/env bash
# validate-env.sh
# Pre-flight validation for TAK Server Docker setup.
# Checks that required environment variables are set and valid before deployment.
# Can be sourced to validate or run directly for a report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_ROOT}/.env"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VALIDATION_PASSED=0
VALIDATION_FAILED=0

log_pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((VALIDATION_PASSED++))
}

log_fail() {
  echo -e "${RED}✗${NC} $1"
  ((VALIDATION_FAILED++))
}

log_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
  echo "ℹ $1"
}

validate_var_not_empty() {
  local var_name="$1"
  local var_value="${2:-}"
  
  if [[ -z "$var_value" ]]; then
    log_fail "$var_name is empty or not set"
    return 1
  else
    log_pass "$var_name is set"
    return 0
  fi
}

validate_hostname_or_ip() {
  local input="$1"
  
  # Simple validation: allow alphanumeric, dots, hyphens, and commas
  if [[ $input =~ ^[a-zA-Z0-9.,:-]+$ ]]; then
    return 0
  else
    return 1
  fi
}

validate_dns_name() {
  local name="$1"
  
  # DNS names: alphanumeric, hyphens, dots (no underscores)
  if [[ $name =~ ^[a-zA-Z0-9.-]+$ ]]; then
    return 0
  else
    return 1
  fi
}

validate_client_names() {
  local names="$1"
  local -a name_array
  local IFS=','
  read -ra name_array <<< "$names"
  
  for name in "${name_array[@]}"; do
    # Trim whitespace
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    
    # Check for safe characters (alphanumeric, underscore, hyphen)
    if ! [[ $name =~ ^[a-zA-Z0-9_-]+$ ]]; then
      return 1
    fi
  done
  return 0
}

validate_tak_version_file() {
  local version="$1"
  local tak_file="${PROJECT_ROOT}/takserver-docker-${version}.zip"
  
  if [[ -f "$tak_file" ]]; then
    return 0
  else
    return 1
  fi
}

validate_password_strength() {
  local password="$1"
  
  # Minimum 6 characters (TAK standard)
  if [[ ${#password} -lt 6 ]]; then
    return 1
  fi
  return 0
}

# Main validation
echo "════════════════════════════════════════════════════════════════"
echo "TAK Server Environment Validation"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Check if .env exists
if [[ ! -f "$ENV_FILE" ]]; then
  log_fail ".env file not found at $ENV_FILE"
  echo ""
  echo "Please create .env by copying .env.example:"
  echo "  cp ${PROJECT_ROOT}/.env.example ${ENV_FILE}"
  exit 1
fi
log_pass ".env file exists"

# Source .env
source "$ENV_FILE" || {
  log_fail "Failed to source .env file"
  exit 1
}

echo ""
echo "Configuration Validation:"

# Check required variables
echo ""
echo "Required Variables:"
validate_var_not_empty "TAK_VERSION" "${TAK_VERSION:-}" || true
validate_var_not_empty "SERVER_HOSTNAMES" "${SERVER_HOSTNAMES:-}" || true
validate_var_not_empty "CLIENT_NAMES" "${CLIENT_NAMES:-}" || true

# Validate TAK_VERSION file exists
echo ""
echo "TAK Server Release:"
if [[ -n "${TAK_VERSION:-}" ]]; then
  if validate_tak_version_file "$TAK_VERSION"; then
    log_pass "TAK Server release found: takserver-docker-${TAK_VERSION}.zip"
  else
    log_fail "TAK Server release not found: takserver-docker-${TAK_VERSION}.zip"
    log_info "Download from https://tak.gov/products/tak-server and place in project root"
  fi
else
  log_fail "TAK_VERSION not set"
fi

# Validate SERVER_HOSTNAMES
echo ""
echo "Server Configuration:"
if [[ -n "${SERVER_HOSTNAMES:-}" ]]; then
  if validate_hostname_or_ip "$SERVER_HOSTNAMES"; then
    log_pass "SERVER_HOSTNAMES format looks valid: $SERVER_HOSTNAMES"
    # Check if first hostname is valid DNS
    first_host=$(echo "$SERVER_HOSTNAMES" | cut -d',' -f1 | xargs)
    if validate_dns_name "$first_host"; then
      log_pass "Primary hostname is valid: $first_host"
    else
      log_warn "Primary hostname contains invalid characters: $first_host"
    fi
  else
    log_fail "SERVER_HOSTNAMES contains invalid characters: $SERVER_HOSTNAMES"
  fi
else
  log_fail "SERVER_HOSTNAMES is empty"
fi

# Validate CLIENT_NAMES
echo ""
echo "Client Configuration:"
if [[ -n "${CLIENT_NAMES:-}" ]]; then
  if validate_client_names "$CLIENT_NAMES"; then
    log_pass "CLIENT_NAMES format looks valid: $CLIENT_NAMES"
    # Count clients
    client_count=$(echo "$CLIENT_NAMES" | tr ',' '\n' | wc -l)
    log_info "Will provision $client_count client(s)"
  else
    log_fail "CLIENT_NAMES contains invalid characters (use alphanumeric, underscore, hyphen)"
  fi
else
  log_fail "CLIENT_NAMES is empty"
fi

# Validate passwords
echo ""
echo "Security Configuration:"
if [[ -n "${TAK_CERT_PASSWORD:-}" ]]; then
  if validate_password_strength "$TAK_CERT_PASSWORD"; then
    log_pass "TAK_CERT_PASSWORD is set (length: ${#TAK_CERT_PASSWORD})"
  else
    log_warn "TAK_CERT_PASSWORD is very short (${#TAK_CERT_PASSWORD} chars; recommend 12+)"
  fi
else
  log_fail "TAK_CERT_PASSWORD is not set"
fi

if [[ -n "${TAK_DB_PASSWORD:-}" || -n "${POSTGRES_PASSWORD:-}" ]]; then
  db_pw="${TAK_DB_PASSWORD:-${POSTGRES_PASSWORD:-}}"
  if validate_password_strength "$db_pw"; then
    log_pass "Database password is set (length: ${#db_pw})"
  else
    log_warn "Database password is very short (${#db_pw} chars; recommend 12+)"
  fi
else
  log_fail "Database password not set (TAK_DB_PASSWORD or POSTGRES_PASSWORD)"
fi

# Validate certificate metadata
echo ""
echo "Certificate Metadata:"
for var in COUNTRY STATE CITY ORGANIZATION ORGANIZATIONAL_UNIT; do
  if [[ -n "${!var:-}" ]]; then
    log_pass "$var is set"
  else
    log_warn "$var not set (will use default)"
  fi
done

# Optional variables check
echo ""
echo "Optional Configuration:"
for var in CA_NAME MULTI_HOST_DP; do
  if [[ -n "${!var:-}" ]]; then
    log_info "$var = ${!var}"
  fi
done

# Summary
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Validation Summary"
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}Passed:${NC} $VALIDATION_PASSED"
echo -e "${RED}Failed:${NC} $VALIDATION_FAILED"
echo ""

if [[ $VALIDATION_FAILED -eq 0 ]]; then
  echo -e "${GREEN}✓ Environment validation passed!${NC}"
  echo ""
  echo "You can now deploy with:"
  echo "  docker compose up -d --build"
  echo ""
  exit 0
else
  echo -e "${RED}✗ Environment validation failed.${NC}"
  echo ""
  echo "Please fix the errors above in $ENV_FILE and try again."
  echo ""
  exit 1
fi
