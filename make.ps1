# make.ps1
# PowerShell makefile equivalent for TAK Server deployment
# Cross-platform build system for Windows, macOS, and Linux

param(
    [Parameter(Position=0)]
    [ValidateSet(
        'help',
        'setup', 'validate', 'deploy', 'start', 'stop', 'restart',
        'verify', 'status', 'test-client', 'logs', 'logs-db', 'logs-all', 'cot-tail', 'cot-sql',
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
  cot-tail             - Tail CoT messaging log inside the container
  cot-sql              - Poll Postgres for the latest CoT events (live feed)

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

function Invoke-InitResources {
    # Idempotent: creates the external volumes + network that docker-compose.yml
    # expects. These survive `docker compose down` and version bumps so the
    # Postgres database and historical logs are not lost when TAK_VERSION
    # changes (which renames the Compose project).
    docker volume create takserver-db-data | Out-Null
    docker volume create takserver-logs    | Out-Null
    docker network create takserver-net 2>$null | Out-Null
}

function Invoke-Deploy {
    Write-Section "Deploy TAK Server"
    Write-Host "Building and deploying containers..."
    
    Invoke-Validate
    Invoke-InitResources
    
    docker compose up -d --build
    
    Write-Host ""
    Write-Host "Containers starting. Monitor with: .\make.ps1 logs"
    Write-Host "Verify deployment with: .\make.ps1 verify"
}

function Invoke-Start {
    Write-Host "Starting containers..."
    Invoke-InitResources
    docker compose up -d
}

function Invoke-Stop {
    Write-Host "Stopping containers..."
    docker compose stop
}

function Invoke-Restart {
    Write-Host "Restarting containers..."
    docker compose stop
    Invoke-InitResources
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
    $containerId = docker compose ps -q takserver
    if (-not $containerId) {
        Write-Host "TAK Server container not found. Start it with '.\make.ps1 deploy' or '.\make.ps1 start'."
        exit 1
    }

    docker exec $containerId bash /opt/tak/scripts/test-client-connection.sh
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

function Invoke-CotTail {
    $containerId = docker compose ps -q takserver
    if (-not $containerId) {
        Write-Host "TAK Server container not found. Start it with '.\make.ps1 deploy' or '.\make.ps1 start'."
        exit 1
    }
    docker exec -it $containerId sh -c 'tail -F /opt/tak/logs/takserver-messaging.log'
}

function Invoke-CotSql {
    $dbContainer = docker compose ps -q takserver-db
    if (-not $dbContainer) {
        Write-Host "Database container not running."
        exit 1
    }
    if (-not (Test-Path $envFile)) {
        Write-Host ".env not found. Run '.\make.ps1 setup' first."
        exit 1
    }
    $pwLine = Select-String -Path $envFile -Pattern '^POSTGRES_PASSWORD=' | Select-Object -First 1
    if (-not $pwLine) { Write-Host "POSTGRES_PASSWORD not set in .env"; exit 1 }
    $pw = ($pwLine.Line -replace '^POSTGRES_PASSWORD=', '').Trim()

    # Reconstruct the full CoT <event> XML from the cot_router columns. The
    # outer envelope (uid/type/how/time/start/stale/point) is column data;
    # the inner <detail>...</detail> XML is stored verbatim in `detail`.
    #
    # NOTE: avoid literal `"` in the SQL because PowerShell mangles double
    # quotes when invoking native executables (docker.exe). We build them
    # with chr(34) inside SQL instead.
    $sqlTemplate = @'
SELECT id || '|' ||
  '<event version=' || chr(34) || '2.0' || chr(34) ||
  ' uid='   || chr(34) || coalesce(uid,'')      || chr(34) ||
  ' type='  || chr(34) || coalesce(cot_type,'') || chr(34) ||
  ' how='   || chr(34) || coalesce(how,'')      || chr(34) ||
  ' time='  || chr(34) || coalesce(to_char(time  at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'') || chr(34) ||
  ' start=' || chr(34) || coalesce(to_char(start at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'') || chr(34) ||
  ' stale=' || chr(34) || coalesce(to_char(stale at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'') || chr(34) ||
  '><point lat=' || chr(34) || coalesce(ST_Y(event_pt)::text,'0')   || chr(34) ||
  ' lon='        || chr(34) || coalesce(ST_X(event_pt)::text,'0')   || chr(34) ||
  ' hae='        || chr(34) || coalesce(point_hae::text,'9999999')  || chr(34) ||
  ' ce='         || chr(34) || coalesce(point_ce::text,'9999999')   || chr(34) ||
  ' le='         || chr(34) || coalesce(point_le::text,'9999999')   || chr(34) ||
  '/>' || coalesce(detail,'') || '</event>'
FROM cot_router WHERE id > {0} ORDER BY id ASC;
'@

    Write-Host "Polling cot_router for new CoT events (full XML). Ctrl-C to stop." -ForegroundColor Yellow
    $lastId = 0
    while ($true) {
        $sql = [string]::Format($sqlTemplate, $lastId)
        $out = docker exec -e PGPASSWORD=$pw $dbContainer psql -h 127.0.0.1 -U martiuser -d cot -A -t -c $sql 2>$null
        if ($out) {
            $out | ForEach-Object {
                if ($_ -match '^(\d+)\|(.*)$') {
                    Write-Host ("{0}: {1}" -f $Matches[1], $Matches[2])
                    if ([int]$Matches[1] -gt $lastId) { $lastId = [int]$Matches[1] }
                }
            }
        }
        Start-Sleep -Seconds 2
    }
}

function Invoke-Clean {
    Write-Host "Removing containers and volumes..."
    docker compose down
    Write-Success "Cleanup complete"
}

function Invoke-Reset {
    Write-Host "Hard reset: removing all data..."
    docker compose down -v
    # External resources are not touched by `down -v`; remove them explicitly.
    docker volume  rm takserver-db-data 2>$null | Out-Null
    docker volume  rm takserver-logs    2>$null | Out-Null
    docker network rm takserver-net     2>$null | Out-Null
    Remove-Item $envFile -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $projectRoot "data" "certs") -Recurse -ErrorAction SilentlyContinue
    Write-Success "Reset complete. Run '.\make.ps1 setup' to reconfigure."
}

function Invoke-Shell {
    $containerId = docker compose ps -q takserver
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
    Invoke-InitResources
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
        'cot-tail'     = { Invoke-CotTail }
        'cot-sql'      = { Invoke-CotSql }
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
