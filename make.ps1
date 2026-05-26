# make.ps1
# PowerShell makefile equivalent for TAK Server deployment
# Cross-platform build system for Windows, macOS, and Linux

param(
    [Parameter(Position=0)]
    [ValidateSet(
        'help',
        'setup', 'validate', 'deploy', 'start', 'stop', 'restart',
        'verify', 'status', 'test-client', 'logs', 'logs-db', 'logs-all',
        'clean', 'reset', 'shell',
        'ci-validate', 'ci-deploy', 'ci-test', 'ci-clean'
    )]
    [string]$Target = 'help',
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = $scriptPath
$dockerDir = Join-Path $projectRoot "docker"
$scriptsDir = Join-Path $projectRoot "scripts"
$envFile = Join-Path $projectRoot ".env"

# ============================================================================
# Output Functions
# ============================================================================

function Write-Success {
    Write-Host "✓ $args" -ForegroundColor Green
}

function Write-Section {
    Write-Host ""
    Write-Host "=== $args ===" -ForegroundColor Blue
    Write-Host ""
}

# ============================================================================
# Help
# ============================================================================

function Show-Help {
    @"
TAK Server Docker Deployment - Makefile (PowerShell)

Usage:
    .\make.ps1 <target>
    make <target>         (requires make.cmd wrapper)

Setup & Configuration:
  setup                - Interactive setup wizard
  validate             - Validate .env configuration

Deployment:
  deploy               - Build and start containers
  start                - Start containers (no rebuild)
  stop                 - Stop running containers
  restart              - Restart containers

Verification & Monitoring:
  verify               - Run post-deployment verification
  status               - Show deployment health status
  test-client          - Test client connection
  logs                 - Tail TAK Server logs
  logs-db              - Tail database logs
  logs-all             - Tail all container logs

Development:
  clean                - Remove containers and volumes
  reset                - Hard reset (removes all data)
  shell                - Open shell in TAK Server container

CI/CD:
  ci-validate          - Validate (for CI/CD pipelines)
  ci-deploy            - Deploy and verify
  ci-test              - Test client connection
  ci-clean             - Cleanup

Examples:
  .\make.ps1 setup
  .\make.ps1 deploy
  .\make.ps1 verify
  .\make.ps1 logs

"@
}

# ============================================================================
# Target Implementations
# ============================================================================

function Invoke-Setup {
    Write-Section "Setup"
    
    $setupScript = Join-Path $projectRoot "setup.ps1"
    if (Test-Path $setupScript) {
        & $setupScript
    }
    else {
        Write-Host "setup.ps1 not found"
        exit 1
    }
}

function Invoke-Validate {
    Write-Section "Validate Configuration"
    
    $validateScript = Join-Path $projectRoot "validate-env.ps1"
    if (Test-Path $validateScript) {
        & $validateScript
    }
    else {
        Write-Host "validate-env.ps1 not found"
        exit 1
    }
}

function Invoke-Deploy {
    Write-Section "Deploy TAK Server"
    Write-Host "Building and deploying containers..."
    
    Invoke-Validate
    
    docker compose up -d --build
    
    Write-Host ""
    Write-Host "Containers starting. Monitor with: .\make.ps1 logs"
    Write-Host "Verify deployment with: .\make.ps1 verify"
}

function Invoke-Start {
    Write-Host "Starting containers..."
    docker compose up -d
}

function Invoke-Stop {
    Write-Host "Stopping containers..."
    docker compose stop
}

function Invoke-Restart {
    Write-Host "Restarting containers..."
    docker compose stop
    docker compose up -d
}

function Invoke-Verify {
    Write-Section "Verify Deployment"
    
    $verifyScript = Join-Path $projectRoot "verify-deployment.ps1"
    if (Test-Path $verifyScript) {
        & $verifyScript
    }
    else {
        Write-Host "verify-deployment.ps1 not found"
        exit 1
    }
}

function Invoke-Status {
    Write-Section "Deployment Status"
    
    $statusScript = Join-Path $projectRoot "status.ps1"
    if (Test-Path $statusScript) {
        & $statusScript
    }
    else {
        Write-Host "status.ps1 not found"
        exit 1
    }
}

function Invoke-TestClient {
    Write-Section "Test Client Connection"
    
    Write-Host "Attempting client connection test..."
    docker exec $(docker ps -q -f "name=takserver") bash /opt/tak/docker/test-client-connection.sh
}

function Invoke-Logs {
    docker compose logs -f takserver
}

function Invoke-LogsDb {
    docker compose logs -f takserver-db
}

function Invoke-LogsAll {
    docker compose logs -f
}

function Invoke-Clean {
    Write-Host "Removing containers and volumes..."
    docker compose down
    Write-Success "Cleanup complete"
}

function Invoke-Reset {
    Write-Host "Hard reset: removing all data..."
    docker compose down -v
    Remove-Item $envFile -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $projectRoot "data" "certs") -Recurse -ErrorAction SilentlyContinue
    Write-Success "Reset complete. Run '.\make.ps1 setup' to reconfigure."
}

function Invoke-Shell {
    $containerId = docker ps -q -f "name=takserver"
    if ($containerId) {
        docker exec -it $containerId /bin/bash
    }
    else {
        Write-Host "TAK Server container not found"
        exit 1
    }
}

# CI/CD targets
function Invoke-CIValidate {
    Invoke-Validate
}

function Invoke-CIDeploy {
    Invoke-Validate
    docker compose up -d --build
    Start-Sleep -Seconds 30
    & (Join-Path $projectRoot "verify-deployment.ps1")
}

function Invoke-CITest {
    Invoke-TestClient
}

function Invoke-CIClean {
    Invoke-Clean
}

# ============================================================================
# Main Dispatcher
# ============================================================================

function Main {
    $targetMap = @{
        'help'         = { Show-Help }
        'setup'        = { Invoke-Setup }
        'validate'     = { Invoke-Validate }
        'deploy'       = { Invoke-Deploy }
        'start'        = { Invoke-Start }
        'stop'         = { Invoke-Stop }
        'restart'      = { Invoke-Restart }
        'verify'       = { Invoke-Verify }
        'status'       = { Invoke-Status }
        'test-client'  = { Invoke-TestClient }
        'logs'         = { Invoke-Logs }
        'logs-db'      = { Invoke-LogsDb }
        'logs-all'     = { Invoke-LogsAll }
        'clean'        = { Invoke-Clean }
        'reset'        = { Invoke-Reset }
        'shell'        = { Invoke-Shell }
        'ci-validate'  = { Invoke-CIValidate }
        'ci-deploy'    = { Invoke-CIDeploy }
        'ci-test'      = { Invoke-CITest }
        'ci-clean'     = { Invoke-CIClean }
    }
    
    if ($targetMap.ContainsKey($Target)) {
        & $targetMap[$Target]
    }
    else {
        Write-Host "Unknown target: $Target"
        Show-Help
        exit 1
    }
}

Main
