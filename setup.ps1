# TAK Server Docker Deployment - Windows/macOS Setup
# PowerShell equivalent of scripts/setup.sh
# Works on Windows PowerShell 7+ and macOS with PowerShell

param(
    [switch]$Help
)

if ($Help) {
    @"
TAK Server Docker Setup (Cross-Platform PowerShell)

Usage:
    PowerShell -ExecutionPolicy Bypass -File setup.ps1

This script creates or updates your .env configuration file interactively.

Features:
    - Detects available TAK Server releases
    - Validates all inputs before saving
    - Creates a properly formatted .env file
    - Color-coded output for easy reading

Requirements:
    - PowerShell 7+ (Core) or Windows PowerShell 5.1+
    - Docker and Docker Compose v2

"@
    exit 0
}

$ErrorActionPreference = 'Stop'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = $scriptPath

# ============================================================================
# Colors & Output Functions
# ============================================================================

function Write-Success {
    Write-Host "✓ $args" -ForegroundColor Green
}

function Write-ErrorCustom {
    Write-Host "✗ $args" -ForegroundColor Red
}

function Write-WarningCustom {
    Write-Host "⚠ $args" -ForegroundColor Yellow
}

function Write-Info {
    Write-Host "ℹ $args" -ForegroundColor Cyan
}

function Write-Section {
    Write-Host "═══ $args ═══" -ForegroundColor Blue
}

# ============================================================================
# Validation Functions
# ============================================================================

function Test-Hostname {
    param([string]$HostnameValue)
    if ($HostnameValue -match '^[a-zA-Z0-9.,:-]+$') {
        return $true
    }
    Write-ErrorCustom "Invalid hostname format"
    return $false
}

function Test-ClientName {
    param([string]$ClientNameValue)
    if ($ClientNameValue -match '^[a-zA-Z0-9_,-]+$') {
        return $true
    }
    Write-ErrorCustom "Invalid client name (use alphanumeric, comma, underscore, hyphen)"
    return $false
}

function Test-TAKVersion {
    param([string]$Version)
    $file = Join-Path $projectRoot "takserver-docker-${Version}.zip"
    if (Test-Path $file) {
        return $true
    }
    Write-ErrorCustom "TAK Server release not found: $file"
    return $false
}

# ============================================================================
# Input Functions
# ============================================================================

function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )
    
    $display = if ($Default) { " [$Default]" } else { "" }
    $response = Read-Host "? $Prompt$display"
    if ($response -ne "") { $response } else { $Default }
}

function Read-PasswordConfirmed {
    param([string]$Prompt)
    
    while ($true) {
        $password = Read-Host "? $Prompt" -AsSecureString
        $passwordText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($password))
        
        $confirm = Read-Host "? Confirm $Prompt" -AsSecureString
        $confirmText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($confirm))
        
        if ($passwordText -eq $confirmText) {
            return $passwordText
        }
        Write-ErrorCustom "Passwords don't match, try again"
    }
}

# ============================================================================
# Setup Steps
# ============================================================================

function Show-Banner {
    Clear-Host
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host "TAK Server Docker Deployment Setup" -ForegroundColor Blue
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
}

function Step-Welcome {
    Show-Banner
    Write-Host "Welcome! This wizard will help you configure TAK Server for Docker deployment."
    Write-Host ""
    Write-Host "Requirements:"
    Write-Host "  • Docker and Docker Compose v2"
    Write-Host "  • TAK Server Docker release (.zip file) in project root"
    Write-Host ""
    $null = Read-Host "Press Enter to continue"
    Write-Host ""
}

function Step-TAKVersion {
    Write-Section "1. TAK Server Release"
    Write-Host ""
    
    Write-Host "Found releases in project root:"
    $releases = @(Get-ChildItem -Path $projectRoot -Filter "takserver-docker-*.zip" -ErrorAction SilentlyContinue | Sort-Object Name)
    
    if ($releases.Count -eq 0) {
        Write-ErrorCustom "No TAK Server releases found!"
        Write-Host ""
        Write-Host "Please download from https://tak.gov/products/tak-server"
        Write-Host "and place the .zip file in: $projectRoot"
        Write-Host ""
        return $null
    }
    
    $defaultVersion = $null
    $releases | ForEach-Object {
        if ($_.Name -match 'takserver-docker-(.+?)\.zip') {
            Write-Host "  • $($Matches[1])"
            if ($null -eq $defaultVersion) {
                $defaultVersion = $Matches[1]
            }
        }
    }
    
    Write-Host ""
    $attempts = 0
    while ($attempts -lt 3) {
        $version = Read-WithDefault "Which version to use?" $defaultVersion
        if (Test-TAKVersion $version) {
            Write-Success "Using TAK Server version: $version"
            return $version
        }
        $attempts++
    }
    
    Write-ErrorCustom "Could not find TAK Server version"
    return $null
}

function Step-ServerConfig {
    Write-Section "2. Server Configuration"
    Write-Host ""
    Write-Host "Configure hostnames where clients will connect to this server."
    Write-Host "Use comma-separated values for multiple hostnames."
    Write-Host ""
    
    $attempts = 0
    while ($attempts -lt 3) {
        $hostnames = Read-WithDefault "Server hostname(s)" "takserver,localhost"
        if (Test-Hostname $hostnames) {
            Write-Success "Server hostnames: $hostnames"
            return $hostnames
        }
        $attempts++
    }
    
    Write-ErrorCustom "Invalid hostname format"
    return $null
}

function Step-ClientConfig {
    Write-Section "3. Client Configuration"
    Write-Host ""
    Write-Host "Configure client usernames. These users will get certificates and Data Packages."
    Write-Host "Use comma-separated values for multiple clients."
    Write-Host ""
    
    $attempts = 0
    while ($attempts -lt 3) {
        $clients = Read-WithDefault "Client username(s)" "client,user2,user3"
        if (Test-ClientName $clients) {
            Write-Success "Client usernames: $clients"
            return $clients
        }
        $attempts++
    }
    
    Write-ErrorCustom "Invalid client names"
    return $null
}

function Step-Passwords {
    Write-Section "4. Security Configuration"
    Write-Host ""
    Write-Host "Configure passwords for certificates and database."
    Write-Host "Recommendations:"
    Write-Host "  • Minimum 8 characters"
    Write-Host "  • Mix of letters, numbers, special characters"
    Write-Host "  • Different passwords for cert and database"
    Write-Host ""
    
    $certPwd = Read-PasswordConfirmed "Certificate password (default: atakatak)"
    $certPwd = if ($certPwd) { $certPwd } else { "atakatak" }
    
    if ($certPwd.Length -lt 6) {
        Write-WarningCustom "Password is very short"
    }
    Write-Success "Certificate password set"
    
    Write-Host ""
    
    $dbPwd = Read-PasswordConfirmed "Database password (default: atakatak)"
    $dbPwd = if ($dbPwd) { $dbPwd } else { "atakatak" }
    
    if ($dbPwd.Length -lt 6) {
        Write-WarningCustom "Password is very short"
    }
    Write-Success "Database password set"
    
    Write-Host ""
    
    return @{
        CertPassword = $certPwd
        DBPassword   = $dbPwd
    }
}

function Step-CertMetadata {
    Write-Section "5. Certificate Metadata (Optional)"
    Write-Host ""
    Write-Host "Press Enter to use defaults."
    Write-Host ""
    
    $metadata = @{
        Country            = Read-WithDefault "Country" "NL"
        State              = Read-WithDefault "State/Province" "XX"
        City               = Read-WithDefault "City" "XX"
        Organization       = Read-WithDefault "Organization" "TAK"
        OrganizationalUnit = Read-WithDefault "Organizational Unit" "TAK"
    }
    
    return $metadata
}

function Step-Advanced {
    Write-Section "6. Advanced Configuration (Optional)"
    Write-Host ""
    
    $response = Read-Host "Generate Data Packages for each (user, host) pair? [y/N]"
    $multiHost = $response -match '^[Yy]$'
    
    if ($multiHost) {
        Write-WarningCustom "This will create multiple .dp.zip files per user"
    }
    
    Write-Host ""
    return $multiHost
}

function Step-Review {
    Show-Banner
    Write-Host "Configuration Summary" -ForegroundColor Green
    Write-Host ""
    Write-Host "TAK Server Release:        $script:TAKVersion"
    Write-Host "Server Hostname(s):        $script:ServerHostnames"
    Write-Host "Client Username(s):        $script:ClientNames"
    Write-Host "Cert Password:             $([string]::new('*', $script:Passwords.CertPassword.Length))"
    Write-Host "DB Password:               $([string]::new('*', $script:Passwords.DBPassword.Length))"
    Write-Host "Certificate Country:       $($script:Metadata.Country)"
    Write-Host "Multi-Host Data Packages:  $script:MultiHost"
    Write-Host ""
}

function Step-Confirm {
    Write-WarningCustom "Ready to save configuration?"
    $response = Read-Host "Continue? [Y/n]"
    
    if ($response -and $response -notmatch '^[Yy]?$') {
        Write-ErrorCustom "Setup cancelled"
        return $false
    }
    
    return $true
}

# ============================================================================
# .env Generation
# ============================================================================

function New-EnvFile {
    $envPath = Join-Path $projectRoot ".env"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    $content = @"
# TAK Server Docker Compose Configuration
# Generated by setup.ps1 on $timestamp

# TAK Server release version (must match .zip file in project root)
TAK_VERSION=$($script:TAKVersion)

# Server hostname(s) - comma-separated, first is CN, all become SANs
SERVER_HOSTNAMES=$($script:ServerHostnames)

# Client username(s) - comma-separated
CLIENT_NAMES=$($script:ClientNames)

# Passwords (change in production!)
TAK_CERT_PASSWORD=$($script:Passwords.CertPassword)
TAK_DB_PASSWORD=$($script:Passwords.DBPassword)
POSTGRES_PASSWORD=$($script:Passwords.DBPassword)
POSTGRES_DB=cot
POSTGRES_USER=martiuser

# Certificate metadata
COUNTRY=$($script:Metadata.Country)
STATE=$($script:Metadata.State)
CITY=$($script:Metadata.City)
ORGANIZATION=$($script:Metadata.Organization)
ORGANIZATIONAL_UNIT=$($script:Metadata.OrganizationalUnit)

# Root CA name
CA_NAME=TAK-Root-CA

# Generate Data Packages for each (user, host) pair (default: false)
MULTI_HOST_DP=$($script:MultiHost.ToString().ToLower())
"@

    Set-Content -Path $envPath -Value $content -Encoding UTF8
    Write-Success "Configuration saved to $envPath"
}

# ============================================================================
# Main Flow
# ============================================================================

function Main {
    # Check for existing .env
    $envPath = Join-Path $projectRoot ".env"
    if (Test-Path $envPath) {
        Write-WarningCustom ".env file already exists"
        $response = Read-Host "Overwrite existing configuration? [y/N]"
        if ($response -notmatch '^[Yy]$') {
            Write-Host "Setup cancelled"
            exit 0
        }
    }
    
    # Run setup steps
    Step-Welcome
    
    $script:TAKVersion = Step-TAKVersion
    if ($null -eq $script:TAKVersion) { exit 1 }
    
    $script:ServerHostnames = Step-ServerConfig
    if ($null -eq $script:ServerHostnames) { exit 1 }
    
    $script:ClientNames = Step-ClientConfig
    if ($null -eq $script:ClientNames) { exit 1 }
    
    $script:Passwords = Step-Passwords
    $script:Metadata = Step-CertMetadata
    $script:MultiHost = Step-Advanced
    
    # Review and confirm
    Step-Review
    if (-not (Step-Confirm)) { exit 1 }
    
    # Generate .env
    Write-Host ""
    Write-Host "Saving configuration..."
    New-EnvFile
    
    Write-Host ""
    Write-Success "Setup complete!"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Review .env: notepad .env"
    Write-Host "  2. Validate configuration: .\validate-env.ps1"
    Write-Host "  3. Start deployment: docker compose up -d --build"
    Write-Host "  4. Monitor startup: docker compose logs -f takserver"
    Write-Host "  5. Verify deployment: .\verify-deployment.ps1"
    Write-Host ""
}

Main
