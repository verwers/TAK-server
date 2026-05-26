#!/usr/bin/env bash
# run-in-docker.sh
# Cross-platform wrapper to run TAK Server scripts inside a Docker container
# Enables bash scripts to work on Windows, macOS, and Linux

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="${PROJECT_ROOT}/docker"
TOOLS_IMAGE="tak-tools:latest"

# ============================================================================
# Usage
# ============================================================================

usage() {
    cat << 'EOF'
TAK Server Cross-Platform Script Runner

Usage:
    ./scripts/run-in-docker.sh <command> [args...]

Commands:
    setup               - Interactive setup wizard
    verify              - Post-deployment verification
    status              - Deployment health check
    validate            - Pre-flight .env validation
    test-client         - Test client connection

Examples:
    ./scripts/run-in-docker.sh setup
    ./scripts/run-in-docker.sh verify
    ./scripts/run-in-docker.sh validate

This wrapper runs scripts inside a Docker container with all required tools,
enabling true cross-platform support (Windows, macOS, Linux).

EOF
    exit 0
}

# ============================================================================
# Build Utility Image
# ============================================================================

build_tools_image() {
    echo "Building TAK tools utility image..."
    docker build -t "$TOOLS_IMAGE" \
        -f "${DOCKER_DIR}/tools.dockerfile" \
        "${PROJECT_ROOT}" \
        2>&1 | grep -v "^Step.*:" || true
    
    if [ $? -eq 0 ]; then
        echo "✓ TAK tools image ready"
    else
        echo "✗ Failed to build TAK tools image"
        exit 1
    fi
}

# ============================================================================
# Run Script in Container
# ============================================================================

run_script() {
    local script_name="$1"
    shift
    local args=("$@")
    
    # Map script names to actual script paths
    case "$script_name" in
        setup)
            local script_path="scripts/setup.sh"
            ;;
        verify)
            local script_path="scripts/verify-deployment.sh"
            ;;
        status)
            local script_path="scripts/status.sh"
            ;;
        validate)
            local script_path="docker/validate-env.sh"
            ;;
        test-client)
            local script_path="docker/test-client-connection.sh"
            ;;
        *)
            echo "Unknown command: $script_name"
            usage
            exit 1
            ;;
    esac
    
    # Ensure script is executable
    chmod +x "${PROJECT_ROOT}/${script_path}" 2>/dev/null || true
    
    echo "Running: $script_name"
    echo ""
    
    # Run script inside container
    docker run --rm \
        -v "${PROJECT_ROOT}:/workspace" \
        -w /workspace \
        --network host \
        "$TOOLS_IMAGE" \
        bash "${script_path}" "${args[@]}"
}

# ============================================================================
# Main
# ============================================================================

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

# Check Docker availability
if ! command -v docker &> /dev/null; then
    echo "✗ Docker not found. Please install Docker Desktop."
    exit 1
fi

# Build tools image if needed
if ! docker image inspect "$TOOLS_IMAGE" &>/dev/null; then
    build_tools_image
fi

# Run requested script
run_script "$@"
