# TAK Server Deployment Verification (Cross-Platform PowerShell)
# Equivalent to scripts/verify-deployment.sh
# Works on Windows PowerShell 7+ and macOS with PowerShell

param(
    [switch]$Help
)

if ($Help) {
    @"
TAK Server Deployment Verification

Usage:
    PowerShell -ExecutionPolicy Bypass -File verify-deployment.ps1

This script verifies that TAK Server deployment is healthy:
    - Containers are running
    - All TAK ports are listening
    - Database is responsive
    - Certificates exist and are valid
    - Data Packages have been generated
    - No startup errors in logs

Exit code: 0 = all checks passed, 1 = failures detected

"@
    exit 0
}

$ErrorActionPreference = 'Stop'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = $scriptPath
$certsDir = Join-Path $projectRoot "data" "certs"

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

# ============================================================================
# Container Detection
# ============================================================================

function Get-ContainerRunning {
    param([string]$ContainerName)
    
    try {
        $output = docker ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
        return $output -like "*$ContainerName*"
    }
    catch {
        return $false
    }
}

function Get-ContainerId {
    param([string]$ContainerName)
    
    try {
        $output = docker ps -q -f "name=$ContainerName" 2>$null
        return $output | Select-Object -First 1
    }
    catch {
        return $null
    }
}

# ============================================================================
# Health Checks
# ============================================================================

function Test-Port {
    param([int]$Port, [string]$HostName = "localhost")
    
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($HostName, $Port)
        $tcp.Close()
        return $true
    }
    catch {
        return $false
    }
}

# ============================================================================
# Main Checks
# ============================================================================

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "TAK Server Deployment Verification" -ForegroundColor Blue
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

$checksPassed = 0
$checksFailed = 0

# Check 1: Containers are running
Write-Host "Container Status:" -ForegroundColor Cyan
Write-Host ""

foreach ($container in @("takserver-db", "takserver")) {
    if (Get-ContainerRunning $container) {
        Write-Success "Container '$container' is running"
        $checksPassed++
    }
    else {
        Write-ErrorCustom "Container '$container' is not running"
        $checksFailed++
    }
}

# Check 2: Ports are listening
Write-Host ""
Write-Host "Port Availability:" -ForegroundColor Cyan
Write-Host ""

$ports = @{
    8089 = "CoT streaming (ATAK clients)"
    8443 = "Marti / Web UI"
    8444 = "Federation (TLS)"
    8446 = "Certificate enrollment"
    9000 = "Federation v2"
    9001 = "Federation v2 (alt)"
}

foreach ($port in $ports.Keys | Sort-Object) {
    if (Test-Port $port) {
        Write-Success "Port $port listening ($($ports[$port]))"
        $checksPassed++
    }
    else {
        Write-ErrorCustom "Port $port not listening ($($ports[$port]))"
        $checksFailed++
    }
}

# Check 3: Database health
Write-Host ""
Write-Host "Database Health:" -ForegroundColor Cyan
Write-Host ""

$dbContainerId = Get-ContainerId "takserver-db"
if ($dbContainerId) {
    try {
        docker exec $dbContainerId sh -c '/usr/lib/postgresql/15/bin/pg_isready -h localhost -U "$POSTGRES_USER" -d "$POSTGRES_DB"' 2>$null
        if ($?) {
            Write-Success "PostgreSQL is responsive on internal network"
            $checksPassed++
        }
        else {
            Write-WarningCustom "PostgreSQL not responding (may still be starting)"
        }
    }
    catch {
        Write-WarningCustom "Could not check PostgreSQL health"
    }
}
else {
    Write-WarningCustom "Database container not found; skipping database check"
}

# Check 4: Certificate files
Write-Host ""
Write-Host "Certificate Files:" -ForegroundColor Cyan
Write-Host ""

if (Test-Path $certsDir) {
    Write-Success "Certificates directory exists: $certsDir"
    $checksPassed++

    $certFiles = @(Get-ChildItem -Path $certsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.p12', '.pem') })
    $certCount = $certFiles.Count
    if ($certCount -gt 0) {
        Write-Success "Found $certCount certificate files"
        $checksPassed++
    }
    else {
        Write-ErrorCustom "No certificate files found in $certsDir"
        $checksFailed++
    }
}
else {
    Write-ErrorCustom "Certificates directory not found at $certsDir"
    $checksFailed++
}

# Check 5: Data Packages
Write-Host ""
Write-Host "Data Packages:" -ForegroundColor Cyan
Write-Host ""

if (Test-Path $certsDir) {
    $dpFiles = @(Get-ChildItem -Path $certsDir -File -Filter "*.dp.zip" -ErrorAction SilentlyContinue)
    $dpCount = $dpFiles.Count
    
    if ($dpCount -gt 0) {
        Write-Success "Found $dpCount Data Package(s)"
        $checksPassed++
        $dpFiles | ForEach-Object {
            Write-Info "  - $($_.Name)"
        }
    }
    else {
        Write-WarningCustom "No Data Packages found (may still be generating on first boot)"
    }
}

# Check 6: Certificate validity
Write-Host ""
Write-Host "Certificate Validity:" -ForegroundColor Cyan
Write-Host ""

$caCandidates = @(
    (Join-Path $certsDir "files" "ca.pem"),
    (Join-Path $certsDir "files" "root-ca.pem"),
    (Join-Path $certsDir "files" "ca.crt"),
    (Join-Path $certsDir "ca.pem"),
    (Join-Path $certsDir "root-ca.pem"),
    (Join-Path $certsDir "ca.crt")
)

$caCert = $caCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($caCert) {
    try {
        # Prefer openssl if available; otherwise use .NET certificate parsing.
        if (Get-Command openssl -ErrorAction SilentlyContinue) {
            $expDate = openssl x509 -in $caCert -noout -enddate 2>$null | ForEach-Object { $_ -replace "notAfter=" }
            $expEpoch = [System.DateTime]::Parse($expDate).ToFileTimeUtc()
            $currentEpoch = (Get-Date).ToFileTimeUtc()
            $daysRemaining = [math]::Floor(($expEpoch - $currentEpoch) / (86400 * 10000000))
            
            if ($daysRemaining -gt 30) {
                Write-Success "CA certificate valid ($daysRemaining days remaining)"
                $checksPassed++
            }
            elseif ($daysRemaining -gt 0) {
                Write-WarningCustom "CA certificate expiring soon ($daysRemaining days remaining)"
            }
            else {
                Write-ErrorCustom "CA certificate expired"
                $checksFailed++
            }
        }
        else {
            $daysRemaining = $null

            # .NET 5+ supports PEM directly with CreateFromPemFile
            $pemFactory = [System.Security.Cryptography.X509Certificates.X509Certificate2].GetMethod("CreateFromPemFile", [Type[]]@([string]))
            if ($pemFactory) {
                $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($caCert)
                $daysRemaining = [math]::Floor((($cert.NotAfter.ToUniversalTime()) - (Get-Date).ToUniversalTime()).TotalDays)
            }
            else {
                # Fallback for non-PEM platforms/runtimes where cert may still load directly
                try {
                    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($caCert)
                    $daysRemaining = [math]::Floor((($cert.NotAfter.ToUniversalTime()) - (Get-Date).ToUniversalTime()).TotalDays)
                }
                catch {
                    Write-Info "openssl not found and runtime cannot parse PEM directly; skipping certificate expiry check"
                }
            }

            if ($null -ne $daysRemaining) {
                if ($daysRemaining -gt 30) {
                    Write-Success "CA certificate valid ($daysRemaining days remaining)"
                    $checksPassed++
                }
                elseif ($daysRemaining -gt 0) {
                    Write-WarningCustom "CA certificate expiring soon ($daysRemaining days remaining)"
                }
                else {
                    Write-ErrorCustom "CA certificate expired"
                    $checksFailed++
                }
            }
        }
    }
    catch {
        Write-WarningCustom "Could not check certificate validity"
    }
}
else {
    Write-WarningCustom "CA certificate not found; skipping validity check"
}

# Check 7: TAK Server startup status
Write-Host ""
Write-Host "TAK Server Startup:" -ForegroundColor Cyan
Write-Host ""

if ($takserverId) {
    try {
        $logs = docker logs $takserverId 2>&1 | Select-String -Pattern "error|failed|exception" -CaseSensitive -ErrorAction SilentlyContinue
        if ($logs.Count -eq 0) {
            Write-Success "No errors detected in TAK Server logs"
            $checksPassed++
        }
        else {
            Write-ErrorCustom "Found errors in TAK Server logs:"
            $logs | Select-Object -First 3 | ForEach-Object {
                Write-Info "  $_"
            }
            $checksFailed++
        }
        
        # Check if TAK Server is fully started
        if (docker logs $takserverId 2>&1 | Select-String -Pattern "listening on port 8089|Marti started|TAK Server started" -CaseSensitive -ErrorAction SilentlyContinue) {
            Write-Success "TAK Server appears to be fully started"
            $checksPassed++
        }
        else {
            Write-WarningCustom "TAK Server startup may still be in progress"
        }
    }
    catch {
        Write-WarningCustom "Could not check TAK Server startup status"
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "Verification Summary" -ForegroundColor Blue
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "Passed: $checksPassed" -ForegroundColor Green
Write-Host "Failed: $checksFailed" -ForegroundColor Red
Write-Host ""

if ($checksFailed -eq 0) {
    Write-Success "All checks passed! Deployment appears healthy."
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Download a .dp.zip Data Package from: $certsDir"
    Write-Host "  2. Import it into ATAK on a client device"
    Write-Host "  3. Attempt to connect to the server"
    Write-Host ""
    exit 0
}
else {
    Write-ErrorCustom "Some checks failed. Review output above for details."
    Write-Host ""
    Write-Host "Troubleshooting:"
    Write-Host "  - Check if containers are still starting: docker compose logs -f"
    Write-Host "  - Verify .env configuration: Get-Content .env"
    Write-Host "  - Check TAK Server logs: docker logs `$(docker ps -q -f name=takserver)"
    Write-Host ""
    exit 1
}
