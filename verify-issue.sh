#!/bin/bash
# ==============================================================================
# Script: verify-issue.sh
# Description: E2E verification for pipeline issues (ready_for_test stage).
#              Checks out the PR branch, runs e2e tests, transitions labels.
#              Pass → ready_for_test → verified
#              Fail → ready_for_test → ready_for_dev
#
# Usage:       ./verify-issue.sh <issue-number> [flags...]
# Example:     ./verify-issue.sh 42
#              ./verify-issue.sh 42 --auto
#              ./verify-issue.sh 42 --model sonnet
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_ROOT}/logs/verify-$(date +%Y%m%d-%H%M%S).log"
ISSUE_NUM="${1:-}"

# Parse flags
AUTO_MODE=""
MODEL_FLAG="--model sonnet"  # default: sonnet for e2e (execution task)

ARGS=("$@")
for i in "${!ARGS[@]}"; do
    case "${ARGS[$i]}" in
        --auto) AUTO_MODE="true" ;;
        --model)
            if [[ -n "${ARGS[$((i+1))]:-}" ]]; then
                MODEL_FLAG="--model ${ARGS[$((i+1))]}"
            fi
            ;;
    esac
done

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
    if [[ -z "$ISSUE_NUM" ]] || ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
        error "Usage: $0 <issue-number> [--auto] [--model <model>]"
        exit 1
    fi
    command -v claude &>/dev/null || { error "Claude CLI not found"; exit 1; }
    command -v gh &>/dev/null || { error "GitHub CLI not found"; exit 1; }
    command -v jq &>/dev/null || { error "jq not found"; exit 1; }
    success "Pre-flight passed"
}

# ------------------------------------------------------------------------------
# PR Branch Checkout (find PR linked to issue, checkout its branch)
# ------------------------------------------------------------------------------

checkout_pr_branch() {
    local pr_branch

    # Search by issue reference in PR body
    pr_branch=$(gh pr list --state open --json headRefName,body \
        --jq ".[] | select(.body | contains(\"#${ISSUE_NUM}\")) | .headRefName" 2>/dev/null | head -1)

    # Fallback: search by issue number in PR title
    if [[ -z "$pr_branch" ]]; then
        pr_branch=$(gh pr list --state open --json headRefName,title \
            --jq ".[] | select(.title | contains(\"#${ISSUE_NUM}\")) | .headRefName" 2>/dev/null | head -1)
    fi

    if [[ -n "$pr_branch" ]]; then
        info "Checking out PR branch: $pr_branch"
        git fetch origin "$pr_branch" 2>/dev/null || true
        git checkout "$pr_branch" 2>/dev/null || \
            git checkout -b "$pr_branch" "origin/$pr_branch" 2>/dev/null || true
        return 0
    else
        warn "No PR branch found for issue #$ISSUE_NUM — testing on current branch"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Label Transitions
# ------------------------------------------------------------------------------

transition_label() {
    local remove_label="$1"
    local add_label="$2"

    [[ -n "$remove_label" ]] && gh issue edit "$ISSUE_NUM" --remove-label "$remove_label" 2>/dev/null || true
    [[ -n "$add_label" ]] && gh issue edit "$ISSUE_NUM" --add-label "$add_label" 2>/dev/null || true
    info "Label transition: -$remove_label +$add_label"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "Verify Issue #$ISSUE_NUM"
    info "Model: $MODEL_FLAG"
    [[ "$AUTO_MODE" == "true" ]] && info "Mode: auto (YOLO)"
    info "=========================================="

    cd "$PROJECT_ROOT"
    preflight

    # Validate issue is open
    local issue_json
    issue_json=$(gh issue view "$ISSUE_NUM" --json title,state)
    local issue_state=$(echo "$issue_json" | jq -r '.state')
    local issue_title=$(echo "$issue_json" | jq -r '.title')

    if [[ "$issue_state" != "OPEN" ]]; then
        error "Issue #$ISSUE_NUM is not open (state: $issue_state)"
        exit 1
    fi

    info "Issue: $issue_title"

    # Checkout PR branch
    checkout_pr_branch

    # Health check
    if command -v curl &> /dev/null; then
        curl -sf http://localhost:9000/health > /dev/null 2>&1 || {
            warn "Medusa API not running at localhost:9000 - skipping e2e"
            git checkout main 2>/dev/null || true
            return 1
        }
    fi

    # Build claude flags
    local flags=""
    [[ "$AUTO_MODE" == "true" ]] && flags="--dangerously-skip-permissions"

    # Run e2e via Claude
    info "Running e2e tests..."
    local exit_code=0
    local e2e_output
    e2e_output=$(claude -p "Run e2e-test scenarios to verify fix for issue #$ISSUE_NUM: $issue_title.
Use the e2e-test skill. Run these scenarios: create-account, purchase-success.
You MUST actually execute browser tests using agent-browser. Code analysis alone is NOT acceptable.
Report pass/fail for each scenario." $flags $MODEL_FLAG --continue --output-format text 2>&1) || exit_code=$?

    echo "$e2e_output" | tee -a "$LOG_FILE"

    # Validate tests were actually executed (not just code analysis)
    if echo "$e2e_output" | grep -qiE "not run|no browser execution|code review only|code analysis|could not.*run|unable to.*run|permission.*denied|skipped.*browser"; then
        warn "E2E tests were NOT actually executed (agent did code analysis only)"
        exit_code=1
    fi

    # Transition labels based on result
    if [[ $exit_code -eq 0 ]]; then
        transition_label "ready_for_test" "verified"
        success "E2E passed — issue #$ISSUE_NUM verified"
    else
        transition_label "ready_for_test" "ready_for_dev"
        warn "E2E failed — issue #$ISSUE_NUM re-queued for dev"
    fi

    # Always return to main
    git checkout main 2>/dev/null || true

    echo ""
    info "=========================================="
    success "VERIFY COMPLETE"
    info "=========================================="
    echo "Issue:  #$ISSUE_NUM"
    echo "Result: $([[ $exit_code -eq 0 ]] && echo "PASSED" || echo "FAILED")"
    echo "Log:    $LOG_FILE"
    info "=========================================="

    return $exit_code
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
