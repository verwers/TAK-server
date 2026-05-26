# TAK Server Deployment Status (Cross-Platform PowerShell)
# Equivalent to scripts/status.sh
# Works on Windows PowerShell 7+ and macOS with PowerShell

param(
    [switch]$Help
)

if ($Help) {
    @"
TAK Server Deployment Health Check

Usage:
    PowerShell -ExecutionPolicy Bypass -File status.ps1

Shows comprehensive deployment status:
    - Container status
    - Port availability
    - Database health and size
    - Certificate status and expiry
    - TAK Server process status
    - Recent logs

"@
    exit 0
}

$ErrorActionPreference = 'Continue'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = $scriptPath
$certsDir = Join-Path $projectRoot "data" "certs"

# ============================================================================
# Output Functions
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
    Write-Host ""
    Write-Host "═══ $args ═══" -ForegroundColor Blue
}

# ============================================================================
# Container Detection
# ============================================================================

function Get-ContainerRunning {
    param([string]$ContainerName)
    try {
        $output = docker ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
        return $output -like "*$ContainerName*"
    }
    catch { return $false }
}

function Get-ContainerId {
    param([string]$ContainerName)
    try {
        return docker ps -q -f "name=$ContainerName" 2>$null | Select-Object -First 1
    }
    catch { return $null }
}

# ============================================================================
# Health Checks
# ============================================================================

function Test-Port {
    param([int]$Port)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("localhost", $Port)
        $tcp.Close()
        return $true
    }
    catch { return $false }
}

# ============================================================================
# Main Status Report
# ============================================================================

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "TAK Server Deployment Status" -ForegroundColor Blue
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Write-Section "Container Status"

foreach ($container in @("takserver-db", "takserver")) {
    if (Get-ContainerRunning $container) {
        Write-Success "$container is running"
    }
    else {
        Write-ErrorCustom "$container is not running"
    }
}

# Port availability
Write-Section "Port Availability"

$ports = @{
    8089 = "CoT streaming (ATAK)"
    8443 = "Marti / Web UI"
    8444 = "Federation"
    8446 = "Cert enrollment"
    9000 = "Federation v2"
    9001 = "Federation v2 (alt)"
}

foreach ($port in $ports.Keys | Sort-Object) {
    if (Test-Port $port) {
        Write-Success "Port $port listening ($($ports[$port]))"
    }
    else {
        Write-WarningCustom "Port $port not listening ($($ports[$port]))"
    }
}

# Database health
Write-Section "Database Status"

$takserverId = Get-ContainerId "takserver"
if ($takserverId) {
    if (@(docker exec $takserverId pg_isready -h tak-database -U postgres 2>&1) -match "accepting") {
        Write-Success "PostgreSQL is responsive"
        
        try {
            $dbSize = docker exec $takserverId psql -U postgres -d cot -t -c "SELECT pg_size_pretty(pg_database_size('cot'))" 2>$null
            if ($dbSize) {
                Write-Info "Database size: $dbSize"
            }
        }
        catch { }
    }
    else {
        Write-ErrorCustom "PostgreSQL not responding"
    }
}
else {
    Write-ErrorCustom "TAK Server container not found"
}

# Certificate status
Write-Section "Certificate Status"

if (Test-Path $certsDir) {
    $caCert = Join-Path $certsDir "files" "ca.pem"
    if (Test-Path $caCert) {
        try {
            if (Get-Command openssl -ErrorAction SilentlyContinue) {
                $expDate = openssl x509 -in $caCert -noout -enddate 2>$null | ForEach-Object { $_ -replace "notAfter=" }
                $expEpoch = [System.DateTime]::Parse($expDate).ToFileTimeUtc()
                $currentEpoch = (Get-Date).ToFileTimeUtc()
                $daysRemaining = [math]::Floor(($expEpoch - $currentEpoch) / (86400 * 10000000))
                
                if ($daysRemaining -gt 30) {
                    Write-Success "CA certificate valid ($daysRemaining days remaining)"
                }
                elseif ($daysRemaining -gt 0) {
                    Write-WarningCustom "CA certificate expiring soon ($daysRemaining days remaining)"
                }
                else {
                    Write-ErrorCustom "CA certificate expired"
                }
            }
        }
        catch { Write-Info "Could not check certificate expiry" }
    }
    else {
        Write-WarningCustom "CA certificate not found"
    }
    
    $certCount = @(Get-ChildItem -Path $certsDir -MaxDepth 1 -Include "*.p12", "*.pem" -ErrorAction SilentlyContinue).Count
    Write-Info "Certificates: $certCount files"
    
    $dpCount = @(Get-ChildItem -Path $certsDir -MaxDepth 1 -Filter "*.dp.zip" -ErrorAction SilentlyContinue).Count
    Write-Info "Data Packages: $dpCount files"
}
else {
    Write-WarningCustom "Certificates directory not found"
}

# TAK Server status
Write-Section "TAK Server Status"

if ($takserverId) {
    $logs = docker logs $takserverId 2>&1
    
    if ($logs | Select-String -Pattern "listening on port 8089|Marti started|TAK Server started" -CaseSensitive -ErrorAction SilentlyContinue) {
        Write-Success "TAK Server appears to be running"
    }
    elseif ($logs | Select-String -Pattern "error|exception" -CaseSensitive -ErrorAction SilentlyContinue) {
        Write-ErrorCustom "TAK Server has errors (check logs)"
        $logs | Select-String -Pattern "error" -CaseSensitive -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object {
            Write-Info "  Recent error: $(($_.ToString().Substring(0, [math]::Min(80, $_.ToString().Length))))..."
        }
    }
    else {
        Write-WarningCustom "TAK Server status unclear (may still be starting)"
    }
}
else {
    Write-ErrorCustom "TAK Server container not found"
}

# Initialization log
Write-Section "Initialization Log"

if ($takserverId) {
    if (@(docker exec $takserverId test -f /opt/tak/logs/init.log 2>&1) -match "^$") {
        Write-Host "Last initialization entries:"
        docker exec $takserverId tail -5 /opt/tak/logs/init.log 2>$null | ForEach-Object {
            Write-Host "  $_"
        }
    }
    else {
        Write-WarningCustom "Initialization log not found"
    }
}

Write-Host ""
