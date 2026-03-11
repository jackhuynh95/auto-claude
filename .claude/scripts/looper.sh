#!/bin/bash
# ==============================================================================
# Script: looper.sh
# Description: Scans GitHub issues by pipeline label and dispatches fix-issue.sh
#              with appropriate flags. The "commander" that /loop calls.
#
# Usage:
#   bash .claude/scripts/looper.sh                          # full scan
#   bash .claude/scripts/looper.sh --label ready_for_dev    # single label
#   bash .claude/scripts/looper.sh --dry-run                # scan only
#   bash .claude/scripts/looper.sh --limit 3                # cap per run
#   bash .claude/scripts/looper.sh --profile overnight      # scheduling profile
#
# Via /loop (Claude Code built-in, runs prompt on interval):
#   /loop 2h bash .claude/scripts/looper.sh
#   /loop 2h bash .claude/scripts/looper.sh --profile overnight
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/looper-$(date +%Y%m%d-%H%M%S).log"

# Defaults
DRY_RUN=""
LIMIT=10
FILTER_LABEL=""
PROFILE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse flags
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    case "${ARGS[$i]}" in
        --dry-run) DRY_RUN="true" ;;
        --limit)
            LIMIT="${ARGS[$((i+1))]:-10}"
            ;;
        --label)
            FILTER_LABEL="${ARGS[$((i+1))]:-}"
            ;;
        --profile)
            PROFILE="${ARGS[$((i+1))]:-}"
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

mkdir -p "$LOG_DIR"

log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }

# ------------------------------------------------------------------------------
# Profile Loading (Issue 05)
# ------------------------------------------------------------------------------

PROFILE_LABELS=""
PROFILE_FLAGS=""
PROFILE_LIMIT=""
PROFILE_SUMMARY=""

load_profile() {
    local profile_file="${SCRIPT_DIR}/looper-profiles.sh"
    if [[ -f "$profile_file" ]]; then
        source "$profile_file"
    fi

    case "$PROFILE" in
        overnight)
            PROFILE_LABELS="ready_for_dev"
            PROFILE_FLAGS="--auto --hard --worktree"
            PROFILE_LIMIT=5
            ;;
        morning)
            PROFILE_LABELS="ready_for_test"
            PROFILE_FLAGS="--e2e-only"
            PROFILE_LIMIT=10
            PROFILE_SUMMARY="true"
            ;;
        daytime)
            PROFILE_LABELS="ready_for_test"
            PROFILE_FLAGS="--e2e-only"
            PROFILE_LIMIT=3
            ;;
        continuous)
            PROFILE_LABELS="ready_for_dev,ready_for_test"
            PROFILE_FLAGS="--auto --worktree"
            PROFILE_LIMIT=3
            ;;
        "")
            # No profile, use defaults
            ;;
        *)
            # Check if profile function exists from looper-profiles.sh
            if type "profile_${PROFILE}" &>/dev/null; then
                "profile_${PROFILE}"
                PROFILE_LABELS="${LABELS:-}"
                PROFILE_FLAGS="${FLAGS:-}"
                PROFILE_LIMIT="${LIMIT:-}"
                PROFILE_SUMMARY="${SUMMARY:-}"
            else
                warn "Unknown profile: $PROFILE (using defaults)"
            fi
            ;;
    esac

    # Profile overrides (CLI flags take precedence)
    [[ -z "$FILTER_LABEL" ]] && [[ -n "$PROFILE_LABELS" ]] && FILTER_LABEL="$PROFILE_LABELS"
    [[ -n "$PROFILE_LIMIT" ]] && LIMIT="$PROFILE_LIMIT"
}

# ------------------------------------------------------------------------------
# Pipeline Summary
# ------------------------------------------------------------------------------

print_summary() {
    local ready_dev=$(gh issue list --label "ready_for_dev" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local ready_test=$(gh issue list --label "ready_for_test" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local shipped=$(gh issue list --label "shipped" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local verified=$(gh issue list --label "verified" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local blocked=$(gh issue list --label "blocked" --state open --json number --jq 'length' 2>/dev/null || echo "?")

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}  Pipeline Summary — $(date '+%Y-%m-%d %H:%M')${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "  ready_for_dev:   ${ready_dev} issues"
    echo -e "  ready_for_test:  ${ready_test} issues"
    echo -e "  shipped:         ${shipped} issues"
    echo -e "  verified:        ${verified} issues"
    echo -e "  blocked:         ${blocked} issues"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# Issue Processing
# ------------------------------------------------------------------------------

process_issues_by_label() {
    local label="$1"
    local flags="$2"
    local processed=0

    info "Scanning issues with label: $label"

    local issues=$(gh issue list --label "$label" --label "pipeline" --state open --json number,title --limit "$LIMIT" 2>/dev/null || echo "[]")
    local count=$(echo "$issues" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        info "No issues found with label: $label"
        return 0
    fi

    info "Found $count issue(s) with label: $label"

    for row in $(echo "$issues" | jq -r '.[] | @base64'); do
        local num=$(echo "$row" | base64 --decode | jq -r '.number')
        local title=$(echo "$row" | base64 --decode | jq -r '.title')

        info "Processing #$num: $title"

        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY RUN] Would run: ./fix-issue.sh $num $flags"
        else
            # Dispatch to fix-issue.sh
            cd "$PROJECT_ROOT"
            bash "${PROJECT_ROOT}/fix-issue.sh" "$num" $flags 2>&1 | tee -a "$LOG_FILE" || {
                warn "fix-issue.sh failed for #$num"
            }
        fi

        ((processed++))

        if [[ $processed -ge $LIMIT ]]; then
            info "Reached limit ($LIMIT) — stopping"
            break
        fi
    done

    return $processed
}

# ------------------------------------------------------------------------------
# Label → Action Routing
# ------------------------------------------------------------------------------

route_by_label() {
    local label="$1"
    local extra_flags="${PROFILE_FLAGS:-}"

    case "$label" in
        ready_for_dev)
            process_issues_by_label "ready_for_dev" "--auto --worktree $extra_flags"
            ;;
        ready_for_test)
            process_issues_by_label "ready_for_test" "--e2e-only $extra_flags"
            ;;
        verified)
            # Close verified issues
            info "Closing verified issues..."
            local issues=$(gh issue list --label "verified" --state open --json number --limit "$LIMIT" 2>/dev/null || echo "[]")
            for row in $(echo "$issues" | jq -r '.[] | @base64'); do
                local num=$(echo "$row" | base64 --decode | jq -r '.number')
                if [[ "$DRY_RUN" == "true" ]]; then
                    info "[DRY RUN] Would close issue #$num"
                else
                    gh issue close "$num" 2>/dev/null || warn "Failed to close #$num"
                    success "Closed #$num"
                fi
            done
            ;;
        blocked)
            # Log blocked issues, skip
            local issues=$(gh issue list --label "blocked" --state open --json number,title --limit 50 2>/dev/null || echo "[]")
            local count=$(echo "$issues" | jq 'length')
            warn "$count blocked issue(s) — skipping"
            ;;
        *)
            warn "Unknown label: $label"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "Looper Pipeline Scanner"
    info "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    [[ -n "$PROFILE" ]] && info "Profile: $PROFILE"
    [[ -n "$FILTER_LABEL" ]] && info "Label filter: $FILTER_LABEL"
    [[ "$DRY_RUN" == "true" ]] && info "Mode: DRY RUN"
    info "Limit: $LIMIT issues per label"
    info "=========================================="

    cd "$PROJECT_ROOT"

    # Load profile if specified
    [[ -n "$PROFILE" ]] && load_profile

    # Print summary if profile requests it or morning profile
    if [[ "$PROFILE_SUMMARY" == "true" ]]; then
        print_summary
    fi

    # Route based on filter or scan all pipeline labels
    if [[ -n "$FILTER_LABEL" ]]; then
        # Handle comma-separated labels
        IFS=',' read -ra LABELS <<< "$FILTER_LABEL"
        for label in "${LABELS[@]}"; do
            route_by_label "$(echo "$label" | xargs)"  # trim whitespace
        done
    else
        # Default: process all pipeline stages in order
        route_by_label "ready_for_dev"
        route_by_label "ready_for_test"
        route_by_label "verified"
        route_by_label "blocked"
    fi

    # Always print summary at end
    print_summary

    success "Looper scan complete"
    info "Log: $LOG_FILE"
}

main
