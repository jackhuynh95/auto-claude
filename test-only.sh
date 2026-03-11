#!/bin/bash
# ==============================================================================
# Script: test-only.sh
# Description: Run tests via Claude CLI /test command
#
# Usage:       ./test-only.sh [options] [args-for-test]
# Example:     ./test-only.sh
#              ./test-only.sh --fix
#              ./test-only.sh "run unit tests only"
#              ./test-only.sh --fix "focus on auth module"
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_ROOT}/logs/test-only-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo -e "[$1] $2" | tee -a "$LOG_FILE"; }
info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "OK" "${GREEN}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

preflight() {
    command -v claude &>/dev/null || { error "Claude CLI not found"; exit 1; }
    success "Pre-flight passed"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    local branch=$(git branch --show-current)
    local fix_mode=false
    local test_args=""

    # Parse arguments
    for arg in "$@"; do
        if [[ "$arg" == "--fix" ]]; then
            fix_mode=true
        else
            test_args="$test_args $arg"
        fi
    done
    test_args=$(echo "$test_args" | xargs) # trim whitespace

    info "=========================================="
    info "🧪 Test Only: Branch $branch"
    info "=========================================="

    cd "$PROJECT_ROOT"
    preflight

    local flags=""
    if $fix_mode; then
        flags="--dangerously-skip-permissions"
        warn "Fix mode enabled (YOLO)"
    fi

    # Build command
    local cmd="/test"
    if [[ -n "$test_args" ]]; then
        cmd="/test $test_args"
    fi

    # Run /test command via Claude CLI
    info "Running: $cmd"
    claude -p "$cmd" $flags --output-format text 2>&1 | tee -a "$LOG_FILE"

    success "=========================================="
    success "🧪 TEST COMPLETE"
    success "=========================================="
    echo "Log: $LOG_FILE"
    success "=========================================="
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
