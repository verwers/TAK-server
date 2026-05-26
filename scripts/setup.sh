#!/usr/bin/env bash
# setup.sh
# Interactive setup wizard for TAK Server Docker deployment.
# Guides users through .env configuration with validation and sensible defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# Prompt Functions
# ============================================================================

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local varname="$3"
  local value
  
  read -p "$(echo -e "${BLUE}?${NC} $prompt ${YELLOW}[$default]${NC}: ")" value
  value="${value:-$default}"
  
  eval "$varname='$value'"
}

prompt_yes_no() {
  local prompt="$1"
  local varname="$2"
  local default="${3:-n}"
  local response
  
  if [[ "$default" == "y" ]]; then
    read -p "$(echo -e "${BLUE}?${NC} $prompt ${YELLOW}[Y/n]${NC}: ")" response
    response="${response:-y}"
  else
    read -p "$(echo -e "${BLUE}?${NC} $prompt ${YELLOW}[y/N]${NC}: ")" response
    response="${response:-n}"
  fi
  
  if [[ "$response" =~ ^[Yy]$ ]]; then
    eval "$varname='true'"
  else
    eval "$varname='false'"
  fi
}

# ============================================================================
# Validation Functions
# ============================================================================

validate_hostname() {
  local input="$1"
  if [[ $input =~ ^[a-zA-Z0-9.,:-]+$ ]]; then
    return 0
  else
    echo -e "${RED}✗ Invalid hostname format${NC}"
    return 1
  fi
}

validate_client_name() {
  local input="$1"
  if [[ $input =~ ^[a-zA-Z0-9_,-]+$ ]]; then
    return 0
  else
    echo -e "${RED}✗ Invalid client name (use alphanumeric, comma, underscore, hyphen)${NC}"
    return 1
  fi
}

validate_tak_version() {
  local version="$1"
  local file="${PROJECT_ROOT}/takserver-docker-${version}.zip"
  if [[ -f "$file" ]]; then
    return 0
  else
    echo -e "${RED}✗ TAK Server release not found: $file${NC}"
    return 1
  fi
}

# ============================================================================
# Setup Steps
# ============================================================================

show_banner() {
  clear
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}TAK Server Docker Deployment Setup${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo ""
}

step_welcome() {
  show_banner
  echo "Welcome! This wizard will help you configure TAK Server for Docker deployment."
  echo ""
  echo "Requirements:"
  echo "  • Docker and Docker Compose v2"
  echo "  • TAK Server Docker release (.zip file) placed in project root"
  echo ""
  read -p "Press Enter to continue..."
  echo ""
}

step_tak_version() {
  echo -e "${GREEN}1. TAK Server Release${NC}"
  echo ""
  echo "Found releases in project root:"
  found=0
  while IFS= read -r file; do
    if [[ "$file" =~ takserver-docker-(.+)\.zip ]]; then
      version="${BASH_REMATCH[1]}"
      echo "  • takserver-docker-${version}.zip"
      if [[ -z "$default_version" ]]; then
        default_version="$version"
      fi
      found=$((found + 1))
    fi
  done < <(find "$PROJECT_ROOT" -maxdepth 1 -name "takserver-docker-*.zip" -type f | sort -V | tail -5)
  
  if [[ $found -eq 0 ]]; then
    echo -e "${RED}  No TAK Server releases found!${NC}"
    echo ""
    echo "Please download from https://tak.gov/products/tak-server"
    echo "and place the .zip file in: $PROJECT_ROOT"
    echo ""
    return 1
  fi
  
  echo ""
  local attempts=0
  while [[ $attempts -lt 3 ]]; do
    prompt_with_default "Which version to use?" "${default_version:-5.7-RELEASE-43}" TAK_VERSION
    if validate_tak_version "$TAK_VERSION"; then
      echo -e "${GREEN}✓${NC} Using TAK Server version: $TAK_VERSION"
      break
    fi
    ((attempts++))
  done
  
  if [[ $attempts -ge 3 ]]; then
    echo -e "${RED}✗ Could not find TAK Server version${NC}"
    return 1
  fi
  
  echo ""
}

step_server_config() {
  echo -e "${GREEN}2. Server Configuration${NC}"
  echo ""
  echo "Configure hostnames where clients will connect to this server."
  echo "Use comma-separated values for multiple hostnames."
  echo ""
  
  local attempts=0
  while [[ $attempts -lt 3 ]]; do
    prompt_with_default "Server hostname(s)" "takserver,localhost" SERVER_HOSTNAMES
    if validate_hostname "$SERVER_HOSTNAMES"; then
      echo -e "${GREEN}✓${NC} Server hostnames: $SERVER_HOSTNAMES"
      break
    fi
    ((attempts++))
  done
  
  if [[ $attempts -ge 3 ]]; then
    echo -e "${RED}✗ Invalid hostname format${NC}"
    return 1
  fi
  
  echo ""
}

step_client_config() {
  echo -e "${GREEN}3. Client Configuration${NC}"
  echo ""
  echo "Configure client usernames. These users will get certificates and Data Packages."
  echo "Use comma-separated values for multiple clients."
  echo ""
  
  local attempts=0
  while [[ $attempts -lt 3 ]]; do
    prompt_with_default "Client username(s)" "client,user2,user3" CLIENT_NAMES
    if validate_client_name "$CLIENT_NAMES"; then
      echo -e "${GREEN}✓${NC} Client usernames: $CLIENT_NAMES"
      break
    fi
    ((attempts++))
  done
  
  if [[ $attempts -ge 3 ]]; then
    echo -e "${RED}✗ Invalid client names${NC}"
    return 1
  fi
  
  echo ""
}

step_passwords() {
  echo -e "${GREEN}4. Security Configuration${NC}"
  echo ""
  echo "Configure passwords for certificates and database."
  echo "Recommendations:"
  echo "  • Minimum 8 characters"
  echo "  • Mix of letters, numbers, special characters"
  echo "  • Different passwords for cert and database"
  echo ""
  
  # Certificate password
  while true; do
    read -sp "Certificate password (default: atakatak): " TAK_CERT_PASSWORD
    TAK_CERT_PASSWORD="${TAK_CERT_PASSWORD:-atakatak}"
    echo ""
    
    if [[ ${#TAK_CERT_PASSWORD} -lt 6 ]]; then
      echo -e "${YELLOW}⚠ Password is very short${NC}"
    fi
    
    read -sp "Confirm certificate password: " confirm
    echo ""
    if [[ "$TAK_CERT_PASSWORD" == "$confirm" ]]; then
      echo -e "${GREEN}✓${NC} Certificate password set"
      break
    else
      echo -e "${RED}✗ Passwords don't match, try again${NC}"
    fi
  done
  echo ""
  
  # Database password
  while true; do
    read -sp "Database password (default: atakatak): " TAK_DB_PASSWORD
    TAK_DB_PASSWORD="${TAK_DB_PASSWORD:-atakatak}"
    echo ""
    
    if [[ ${#TAK_DB_PASSWORD} -lt 6 ]]; then
      echo -e "${YELLOW}⚠ Password is very short${NC}"
    fi
    
    read -sp "Confirm database password: " confirm
    echo ""
    if [[ "$TAK_DB_PASSWORD" == "$confirm" ]]; then
      echo -e "${GREEN}✓${NC} Database password set"
      break
    else
      echo -e "${RED}✗ Passwords don't match, try again${NC}"
    fi
  done
  
  echo ""
}

step_certificate_metadata() {
  echo -e "${GREEN}5. Certificate Metadata (Optional)${NC}"
  echo ""
  echo "Configure metadata for generated certificates."
  echo "Press Enter to use defaults."
  echo ""
  
  prompt_with_default "Country" "NL" COUNTRY
  prompt_with_default "State/Province" "XX" STATE
  prompt_with_default "City" "XX" CITY
  prompt_with_default "Organization" "TAK" ORGANIZATION
  prompt_with_default "Organizational Unit" "TAK" ORGANIZATIONAL_UNIT
  
  echo ""
}

step_advanced() {
  echo -e "${GREEN}6. Advanced Configuration (Optional)${NC}"
  echo ""
  
  prompt_yes_no "Generate Data Packages for each (user, host) pair?" MULTI_HOST_DP "y"
  if [[ "$MULTI_HOST_DP" == "true" ]]; then
    echo -e "${YELLOW}⚠ This will create multiple .dp.zip files per user${NC}"
  fi
  
  echo ""
}

step_review() {
  show_banner
  echo -e "${GREEN}Configuration Summary${NC}"
  echo ""
  echo "TAK Server Release:       $TAK_VERSION"
  echo "Server Hostname(s):       $SERVER_HOSTNAMES"
  echo "Client Username(s):       $CLIENT_NAMES"
  echo "Cert Password:            $(printf '%*s' ${#TAK_CERT_PASSWORD} | tr ' ' '*')"
  echo "DB Password:              $(printf '%*s' ${#TAK_DB_PASSWORD} | tr ' ' '*')"
  echo "Certificate Country:      $COUNTRY"
  echo "Certificate State:        $STATE"
  echo "Multi-Host Data Packages: $MULTI_HOST_DP"
  echo ""
}

step_confirm() {
  echo -e "${YELLOW}Ready to save configuration?${NC}"
  read -p "Continue? [Y/n]: " response
  response="${response:-y}"
  
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Setup cancelled${NC}"
    return 1
  fi
  
  return 0
}

# ============================================================================
# Configuration File Generation
# ============================================================================

generate_env_file() {
  cat > "$ENV_FILE" << EOF
# TAK Server Docker Compose Configuration
# Generated by setup.sh on $(date)

# TAK Server release version (must match .zip file in project root)
TAK_VERSION=${TAK_VERSION}

# Server hostname(s) - comma-separated, first is CN, all become SANs
SERVER_HOSTNAMES=${SERVER_HOSTNAMES}

# Client username(s) - comma-separated
CLIENT_NAMES=${CLIENT_NAMES}

# Passwords (change in production!)
TAK_CERT_PASSWORD=${TAK_CERT_PASSWORD}
TAK_DB_PASSWORD=${TAK_DB_PASSWORD}
POSTGRES_PASSWORD=${TAK_DB_PASSWORD}
POSTGRES_DB=cot
POSTGRES_USER=martiuser

# Certificate metadata
COUNTRY=${COUNTRY}
STATE=${STATE}
CITY=${CITY}
ORGANIZATION=${ORGANIZATION}
ORGANIZATIONAL_UNIT=${ORGANIZATIONAL_UNIT}

# Root CA name
CA_NAME=TAK-Root-CA

# Generate Data Packages for each (user, host) pair (default: false)
MULTI_HOST_DP=${MULTI_HOST_DP}
EOF
}

# ============================================================================
# Main Setup Flow
# ============================================================================

main() {
  # Check if .env already exists
  if [[ -f "$ENV_FILE" ]]; then
    echo -e "${YELLOW}⚠ .env file already exists${NC}"
    read -p "Overwrite existing configuration? [y/N]: " response
    response="${response:-n}"
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "Setup cancelled"
      exit 0
    fi
  fi
  
  # Run setup steps
  step_welcome || exit 1
  step_tak_version || exit 1
  step_server_config || exit 1
  step_client_config || exit 1
  step_passwords || exit 1
  step_certificate_metadata
  step_advanced
  
  # Review and confirm
  step_review
  step_confirm || exit 1
  
  # Generate .env file
  echo ""
  echo "Saving configuration..."
  if generate_env_file; then
    echo -e "${GREEN}✓ Configuration saved to ${ENV_FILE}${NC}"
  else
    echo -e "${RED}✗ Failed to save configuration${NC}"
    exit 1
  fi
  
  echo ""
  echo -e "${GREEN}Setup complete!${NC}"
  echo ""
  echo "Next steps:"
  echo "  1. Review .env: cat ${ENV_FILE}"
  echo "  2. Validate configuration: docker/validate-env.sh"
  echo "  3. Start deployment: docker compose up -d --build"
  echo "  4. Monitor startup: docker compose logs -f takserver"
  echo "  5. Verify deployment: scripts/verify-deployment.sh"
  echo ""
}

main "$@"
