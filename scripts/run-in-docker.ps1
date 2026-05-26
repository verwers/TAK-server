# run-in-docker.ps1
# Cross-platform wrapper to run TAK Server scripts inside a Docker container
# Enables bash scripts to work on Windows, macOS, and Linux

param(
    [Parameter(Position=0)]
    [ValidateSet('setup', 'verify', 'status', 'validate', 'test-client', 'help')]
    [string]$Command,
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptPath
$dockerDir = Join-Path $projectRoot "docker"
$toolsImage = "tak-tools:latest"

# ============================================================================
# Output Functions
# ============================================================================

function Write-Success {
    Write-Host "✓ $args" -ForegroundColor Green
}

function Write-ErrorCustom {
    Write-Host "✗ $args" -ForegroundColor Red
}

function Write-Info {
    Write-Host "ℹ $args" -ForegroundColor Cyan
}

# ============================================================================
# Help
# ============================================================================

function Show-Help {
    @"
TAK Server Cross-Platform Script Runner

Usage:
    .\scripts\run-in-docker.ps1 <command> [args]

Commands:
    setup               - Interactive setup wizard
    verify              - Post-deployment verification
    status              - Deployment health check
    validate            - Pre-flight .env validation
    test-client         - Test client connection
    help                - Show this help message

Examples:
    .\scripts\run-in-docker.ps1 setup
    .\scripts\run-in-docker.ps1 verify
    .\scripts\run-in-docker.ps1 validate

This wrapper runs scripts inside a Docker container with all required tools,
enabling true cross-platform support (Windows, macOS, Linux).

"@
}

# ============================================================================
# Docker Utilities
# ============================================================================

function Test-Docker {
    try {
        $null = docker version 2>$null
        return $true
    }
    catch {
        return $false
    }
}

function Build-ToolsImage {
    Write-Host "Building TAK tools utility image..."
    $dockerFile = Join-Path $dockerDir "tools.dockerfile"
    
    docker build -t $toolsImage `
        -f $dockerFile `
        $projectRoot 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "TAK tools image ready"
        return $true
    }
    else {
        Write-ErrorCustom "Failed to build TAK tools image"
        return $false
    }
}

function Test-ImageExists {
    try {
        $null = docker image inspect $toolsImage 2>$null
        return $true
    }
    catch {
        return $false
    }
}

# ============================================================================
# Script Execution
# ============================================================================

function Invoke-ContainerScript {
    param(
        [string]$ScriptName,
        [string[]]$ScriptArgs
    )
    
    $scriptMap = @{
        'setup'       = 'scripts/setup.sh'
        'verify'      = 'scripts/verify-deployment.sh'
        'status'      = 'scripts/status.sh'
        'validate'    = 'docker/validate-env.sh'
        'test-client' = 'docker/test-client-connection.sh'
    }
    
    if (-not $scriptMap.ContainsKey($ScriptName)) {
        Write-ErrorCustom "Unknown command: $ScriptName"
        Show-Help
        exit 1
    }
    
    $scriptPath = $scriptMap[$ScriptName]
    Write-Host "Running: $ScriptName"
    Write-Host ""
    
    # Build docker run command
    $runCmd = @(
        'docker', 'run', '--rm',
        '-v', "$projectRoot`:/workspace",
        '-w', '/workspace',
        '--network', 'host',
        $toolsImage,
        'bash',
        $scriptPath
    )
    
    if ($ScriptArgs.Count -gt 0) {
        $runCmd += $ScriptArgs
    }
    
    # Execute in container
    & $runCmd[0] $runCmd[1..($runCmd.Count-1)]
    return $LASTEXITCODE
}

# ============================================================================
# Main
# ============================================================================

if (-not $Command) {
    Show-Help
    exit 0
}

if ($Command -eq 'help') {
    Show-Help
    exit 0
}

# Check Docker availability
if (-not (Test-Docker)) {
    Write-ErrorCustom "Docker not found. Please install Docker Desktop."
    Write-Host ""
    Write-Host "Download from: https://www.docker.com/products/docker-desktop"
    Write-Host ""
    exit 1
}

# Build tools image if needed
if (-not (Test-ImageExists)) {
    if (-not (Build-ToolsImage)) {
        exit 1
    }
}

# Run requested script
$exitCode = Invoke-ContainerScript $Command $Args
exit $exitCode
