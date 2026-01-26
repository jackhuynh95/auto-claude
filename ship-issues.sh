#!/bin/bash
# ==============================================================================
# Script Name: ship-issues.sh (plural - batch mode)
# Description: Process multiple GitHub issues sequentially via ship-issue.sh
#              Resets to main branch between each issue for clean isolation
#
# Usage:       ./ship-issues.sh <issue-numbers> [--auto]
# Example:     ./ship-issues.sh "39,41,42" --auto
#              ./ship-issues.sh "10,11,12,13"
#
# Flow:        For each issue:
#              1. git checkout main && git pull
#              2. ./ship-issue.sh <issue> [--auto]
#              3. Repeat until all done
#
# Requirements:
#   - ship-issue.sh in same directory
#   - Claude CLI installed and authenticated
#   - GitHub CLI (gh) installed and authenticated
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${PROJECT_ROOT}/logs/ship-batch-$(date +%Y%m%d-%H%M%S).log"
ISSUES_INPUT="${1:-}"
AUTO_FLAG="${2:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Results tracking
declare -a SUCCEEDED=()
declare -a FAILED=()

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }
header() { log "BATCH" "${CYAN}$*${NC}"; }

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

validate_input() {
    if [[ -z "$ISSUES_INPUT" ]]; then
        error "Usage: $0 <issue-numbers> [--auto]"
        error "Example: $0 \"39,41,42\" --auto"
        exit 1
    fi

    # Check ship-issue.sh exists
    if [[ ! -x "$SCRIPT_DIR/ship-issue.sh" ]]; then
        error "ship-issue.sh not found or not executable in $SCRIPT_DIR"
        exit 1
    fi

    # Parse and validate issue numbers
    IFS=',' read -ra ISSUES <<< "$ISSUES_INPUT"

    for issue in "${ISSUES[@]}"; do
        # Trim whitespace
        issue=$(echo "$issue" | xargs)
        if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
            error "Invalid issue number: '$issue' (must be positive integer)"
            exit 1
        fi
    done

    success "Validated ${#ISSUES[@]} issues: ${ISSUES[*]}"
}

# ------------------------------------------------------------------------------
# Reset to Main
# ------------------------------------------------------------------------------

reset_to_main() {
    info "Resetting to main branch..."

    cd "$PROJECT_ROOT"

    # Stash any uncommitted changes
    if [[ -n "$(git status --porcelain)" ]]; then
        warn "Stashing uncommitted changes..."
        git stash push -m "auto-stash-batch-$(date +%H%M%S)"
    fi

    # Checkout main and pull latest
    git checkout main
    git pull origin main --rebase || git pull origin main

    success "Reset to main complete"
}

# ------------------------------------------------------------------------------
# Process Single Issue
# ------------------------------------------------------------------------------

process_issue() {
    local issue="$1"
    local index="$2"
    local total="$3"

    header "=========================================="
    header "Processing Issue #$issue ($index/$total)"
    header "=========================================="

    # Run ship-issue.sh
    if "$SCRIPT_DIR/ship-issue.sh" "$issue" $AUTO_FLAG; then
        success "Issue #$issue completed successfully"
        SUCCEEDED+=("$issue")
        return 0
    else
        error "Issue #$issue failed"
        FAILED+=("$issue")
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Summary Report
# ------------------------------------------------------------------------------

print_summary() {
    echo ""
    header "=========================================="
    header "BATCH PROCESSING COMPLETE"
    header "=========================================="
    echo ""
    echo "Total Issues:  ${#ISSUES[@]}"
    echo -e "Succeeded:     ${GREEN}${#SUCCEEDED[@]}${NC} - [${SUCCEEDED[*]:-none}]"
    echo -e "Failed:        ${RED}${#FAILED[@]}${NC} - [${FAILED[*]:-none}]"
    echo ""
    echo "Log File:      $LOG_FILE"
    header "=========================================="
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    header "=========================================="
    header "BATCH SHIP ISSUES"
    header "Issues: $ISSUES_INPUT"
    header "=========================================="

    cd "$PROJECT_ROOT"

    # Validate
    validate_input

    local total=${#ISSUES[@]}
    local index=0

    # Process each issue sequentially
    for issue in "${ISSUES[@]}"; do
        ((index++))

        # Trim whitespace
        issue=$(echo "$issue" | xargs)

        # Reset to main before each issue
        reset_to_main

        # Process the issue (continue on failure)
        process_issue "$issue" "$index" "$total" || true

        echo ""
    done

    # Final reset to main
    reset_to_main

    # Print summary
    print_summary

    # Exit with error if any failed
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        exit 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
