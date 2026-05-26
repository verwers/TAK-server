# TAK Server Environment Validation (Cross-Platform PowerShell)
# Equivalent to docker/validate-env.sh
# Works on Windows PowerShell 7+ and macOS with PowerShell

param(
    [switch]$Help
)

if ($Help) {
    @"
TAK Server Environment Validation

Usage:
    PowerShell -ExecutionPolicy Bypass -File validate-env.ps1

Validates .env configuration before deployment:
    - .env file exists
    - TAK Server release ZIP is available
    - Required variables are set
    - Hostnames and client names are valid format
    - Passwords meet minimum requirements

Exit code: 0 = validation passed, 1 = validation failed

"@
    exit 0
}

$ErrorActionPreference = 'Continue'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = $scriptPath
$envFile = Join-Path $projectRoot ".env"

# ============================================================================
# Output Functions
# ============================================================================

function Write-Success {
    Write-Host "✓ $args" -ForegroundColor Green
    $script:validationPassed++
}

function Write-ErrorCustom {
    Write-Host "✗ $args" -ForegroundColor Red
    $script:validationFailed++
}

function Write-WarningCustom {
    Write-Host "⚠ $args" -ForegroundColor Yellow
}

function Write-Info {
    Write-Host "ℹ $args" -ForegroundColor Cyan
}

# ============================================================================
# Validation Functions
# ============================================================================

function Test-VarNotEmpty {
    param([string]$VarName, [string]$VarValue)
    
    if ([string]::IsNullOrWhiteSpace($VarValue)) {
        Write-ErrorCustom "$VarName is empty or not set"
        return $false
    }
    else {
        Write-Success "$VarName is set"
        return $true
    }
}

function Test-HostnameFormat {
    param([string]$HostnameValue)
    if ($HostnameValue -match '^[a-zA-Z0-9.,:-]+$') {
        return $true
    }
    return $false
}

function Test-DnsName {
    param([string]$Name)
    if ($Name -match '^[a-zA-Z0-9.-]+$') {
        return $true
    }
    return $false
}

function Test-ClientNames {
    param([string]$Names)
    $nameArray = $Names -split ',' | ForEach-Object { $_.Trim() }
    
    foreach ($name in $nameArray) {
        if (-not ($name -match '^[a-zA-Z0-9_-]+$')) {
            return $false
        }
    }
    return $true
}

function Test-TAKVersionFile {
    param([string]$Version)
    $file = Join-Path $projectRoot "takserver-docker-${Version}.zip"
    return Test-Path $file
}

function Test-PasswordStrength {
    param([securestring]$Password)
    # Minimum 6 characters
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($Password))
    return $plainPassword.Length -ge 6
}

# ============================================================================
# Main Validation
# ============================================================================

$script:validationPassed = 0
$script:validationFailed = 0

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "TAK Server Environment Validation" -ForegroundColor Blue
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

# Check if .env exists
if (Test-Path $envFile) {
    Write-Success ".env file exists"
}
else {
    Write-ErrorCustom ".env file not found at $envFile"
    Write-Host ""
    Write-Host "Please create .env by copying .env.example:"
    Write-Host "  Copy-Item .env.example .env"
    Write-Host ""
    exit 1
}

# Source .env
try {
    $envContent = Get-Content $envFile -Raw
    $envLines = $envContent -split '\n' | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }
    
    $env_vars = @{}
    foreach ($line in $envLines) {
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $value = $value -replace '^"(.+)"$', '$1'  # Remove quotes
            $env_vars[$key] = $value
        }
    }
}
catch {
    Write-ErrorCustom "Failed to parse .env file"
    exit 1
}

Write-Host ""
Write-Host "Configuration Validation:" -ForegroundColor Cyan
Write-Host ""
Write-Host "Required Variables:" -ForegroundColor Cyan
Test-VarNotEmpty "TAK_VERSION" $env_vars["TAK_VERSION"] > $null
Test-VarNotEmpty "SERVER_HOSTNAMES" $env_vars["SERVER_HOSTNAMES"] > $null
Test-VarNotEmpty "CLIENT_NAMES" $env_vars["CLIENT_NAMES"] > $null

# Validate TAK_VERSION file exists
Write-Host ""
Write-Host "TAK Server Release:" -ForegroundColor Cyan
if ($env_vars["TAK_VERSION"]) {
    if (Test-TAKVersionFile $env_vars["TAK_VERSION"]) {
        Write-Success "TAK Server release found: takserver-docker-$($env_vars["TAK_VERSION"]).zip"
    }
    else {
        Write-ErrorCustom "TAK Server release not found: takserver-docker-$($env_vars["TAK_VERSION"]).zip"
        Write-Info "Download from https://tak.gov/products/tak-server and place in project root"
    }
}
else {
    Write-ErrorCustom "TAK_VERSION not set"
}

# Validate SERVER_HOSTNAMES
Write-Host ""
Write-Host "Server Configuration:" -ForegroundColor Cyan
if ($env_vars["SERVER_HOSTNAMES"]) {
    if (Test-HostnameFormat $env_vars["SERVER_HOSTNAMES"]) {
        Write-Success "SERVER_HOSTNAMES format looks valid: $($env_vars["SERVER_HOSTNAMES"])"
        
        $firstHost = ($env_vars["SERVER_HOSTNAMES"] -split ',')[0].Trim()
        if (Test-DnsName $firstHost) {
            Write-Success "Primary hostname is valid: $firstHost"
        }
        else {
            Write-WarningCustom "Primary hostname contains invalid characters: $firstHost"
        }
    }
    else {
        Write-ErrorCustom "SERVER_HOSTNAMES contains invalid characters: $($env_vars["SERVER_HOSTNAMES"])"
    }
}
else {
    Write-ErrorCustom "SERVER_HOSTNAMES is empty"
}

# Validate CLIENT_NAMES
Write-Host ""
Write-Host "Client Configuration:" -ForegroundColor Cyan
if ($env_vars["CLIENT_NAMES"]) {
    if (Test-ClientNames $env_vars["CLIENT_NAMES"]) {
        Write-Success "CLIENT_NAMES format looks valid: $($env_vars["CLIENT_NAMES"])"
        
        $clientCount = ($env_vars["CLIENT_NAMES"] -split ',').Count
        Write-Info "Will provision $clientCount client(s)"
    }
    else {
        Write-ErrorCustom "CLIENT_NAMES contains invalid characters (use alphanumeric, comma, underscore, hyphen)"
    }
}
else {
    Write-ErrorCustom "CLIENT_NAMES is empty"
}

# Validate passwords
Write-Host ""
Write-Host "Security Configuration:" -ForegroundColor Cyan
if ($env_vars["TAK_CERT_PASSWORD"]) {
    if (Test-PasswordStrength ([securestring]::new(($env_vars["TAK_CERT_PASSWORD"].ToCharArray())))) {
        Write-Success "TAK_CERT_PASSWORD is set (length: $($env_vars["TAK_CERT_PASSWORD"].Length))"
    }
    else {
        Write-WarningCustom "TAK_CERT_PASSWORD is very short ($($env_vars["TAK_CERT_PASSWORD"].Length) chars; recommend 12+)"
    }
}
else {
    Write-ErrorCustom "TAK_CERT_PASSWORD is not set"
}

$dbPwd = $env_vars["TAK_DB_PASSWORD"] ?? $env_vars["POSTGRES_PASSWORD"]
if ($dbPwd) {
    if (Test-PasswordStrength ([securestring]::new(($dbPwd.ToCharArray())))) {
        Write-Success "Database password is set (length: $($dbPwd.Length))"
    }
    else {
        Write-WarningCustom "Database password is very short ($($dbPwd.Length) chars; recommend 12+)"
    }
}
else {
    Write-ErrorCustom "Database password not set (TAK_DB_PASSWORD or POSTGRES_PASSWORD)"
}

# Validate certificate metadata
Write-Host ""
Write-Host "Certificate Metadata:" -ForegroundColor Cyan
foreach ($var in @("COUNTRY", "STATE", "CITY", "ORGANIZATION", "ORGANIZATIONAL_UNIT")) {
    if ($env_vars[$var]) {
        Write-Success "$var is set"
    }
    else {
        Write-WarningCustom "$var not set (will use default)"
    }
}

# Optional variables
Write-Host ""
Write-Host "Optional Configuration:" -ForegroundColor Cyan
foreach ($var in @("CA_NAME", "MULTI_HOST_DP")) {
    if ($env_vars[$var]) {
        Write-Info "$var = $($env_vars[$var])"
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "Validation Summary" -ForegroundColor Blue
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "Passed: $script:validationPassed" -ForegroundColor Green
Write-Host "Failed: $script:validationFailed" -ForegroundColor Red
Write-Host ""

if ($script:validationFailed -eq 0) {
    Write-Success "Environment validation passed!"
    Write-Host ""
    Write-Host "You can now deploy with:"
    Write-Host "  docker compose up -d --build"
    Write-Host ""
    exit 0
}
else {
    Write-ErrorCustom "Environment validation failed."
    Write-Host ""
    Write-Host "Please fix the errors above in $envFile and try again."
    Write-Host ""
    exit 1
}
