#!/bin/bash
# ==============================================================================
# Script: ship-issue-no-test.sh
# Description: Ship GitHub issue without running tests (docs, configs, trivial)
#
# Usage:       ./ship-issue-no-test.sh <issue-number>
# Example:     ./ship-issue-no-test.sh 42
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${PROJECT_ROOT}/logs/ship-$(date +%Y%m%d-%H%M%S).log"
ISSUE_NUM="${1:-}"
AUTO_MODE="${2:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------

preflight_check() {
    info "Running pre-flight checks..."

    # Check issue number provided
    if [[ -z "$ISSUE_NUM" ]]; then
        error "Usage: $0 <issue-number> [--auto]"
        exit 1
    fi

    # Check if number
    if ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
        error "Issue number must be a positive integer"
        exit 1
    fi

    # Check Claude CLI
    if ! command -v claude &> /dev/null; then
        error "Claude CLI not found. Install it first."
        exit 1
    fi

    # Check GitHub CLI
    if ! command -v gh &> /dev/null; then
        error "GitHub CLI (gh) not found. Install it first."
        exit 1
    fi

    # Check gh auth
    if ! gh auth status &> /dev/null; then
        error "GitHub CLI not authenticated. Run 'gh auth login' first."
        exit 1
    fi

    # Check issue exists and is open
    if ! gh issue view "$ISSUE_NUM" --json state -q '.state' | grep -qi "open"; then
        error "Issue #$ISSUE_NUM not found or not open"
        exit 1
    fi

    # Check clean working tree
    if [[ -n "$(git status --porcelain)" ]]; then
        warn "Working tree not clean. Stashing changes..."
        git stash push -m "auto-stash-ship-$ISSUE_NUM"
    fi

    success "Pre-flight checks passed"
}

# ------------------------------------------------------------------------------
# Claude CLI Wrapper
# ------------------------------------------------------------------------------

run_claude() {
    local prompt="$1"
    local flags=""

    # Determine mode
    if [[ "$AUTO_MODE" == "--auto" ]] || [[ "${SHIP_AUTO:-false}" == "true" ]]; then
        flags="--dangerously-skip-permissions"
        warn "Running in YOLO mode (auto-approve enabled)"
    fi

    info "Executing Claude command..."

    # Run Claude with prompt
    # Using -p for print mode (non-interactive)
    # --continue to maintain session context
    claude -p "$prompt" $flags --continue --output-format text 2>&1 | tee -a "$LOG_FILE"

    return ${PIPESTATUS[0]}
}

# ------------------------------------------------------------------------------
# Workflow Steps
# ------------------------------------------------------------------------------

step_1_branch_setup() {
    info "Step 1: Issue Analysis & Branch Setup"

    # Fetch issue details using gh's built-in jq (-q flag)
    local issue_title=$(gh issue view "$ISSUE_NUM" --json title -q '.title')
    local has_bug_label=$(gh issue view "$ISSUE_NUM" --json labels -q '.labels | map(.name) | any(. == "bug")')

    # Determine type
    local type="feat"
    if [[ "$has_bug_label" == "true" ]]; then
        type="fix"
    fi

    # Generate branch name
    local slug=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
    local branch="${type}/issue-${ISSUE_NUM}-${slug}"

    # Create branch
    git checkout -b "$branch" 2>/dev/null || {
        warn "Branch $branch already exists, checking out..."
        git checkout "$branch"
    }

    success "Step 1 complete: Branch $branch"
    echo "$branch"
}

step_2_planning() {
    local branch="$1"
    info "Step 2: Planning Phase"

    # Fetch issue for prompt
    local issue_body=$(gh issue view "$ISSUE_NUM" --json title,body -q '"\(.title)\n\n\(.body)"')

    # Run planning command via Claude
    run_claude "/plan:fast Implement GitHub issue #$ISSUE_NUM:

$issue_body

Create implementation plan following project conventions."

    success "Step 2 complete: Plan created"
}

step_3_implementation() {
    info "Step 3: Implementation Phase"

    # Find latest plan
    local plan_path=$(find ./plans -name "plan.md" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [[ -z "$plan_path" ]]; then
        error "No plan found. Step 2 may have failed."
        exit 1
    fi

    # Run implementation
    run_claude "/code:no-test $plan_path"

    success "Step 3 complete: Implementation done"
}

step_4_commit() {
    info "Step 4: Commit Changes"

    # Check if there are changes to commit
    if [[ -z "$(git status --porcelain)" ]]; then
        warn "No changes to commit"
        return 0
    fi

    # Get issue title for commit message
    local issue_title=$(gh issue view "$ISSUE_NUM" --json title -q '.title')
    local has_bug_label=$(gh issue view "$ISSUE_NUM" --json labels -q '.labels | map(.name) | any(. == "bug")')

    local type="feat"
    if [[ "$has_bug_label" == "true" ]]; then
        type="fix"
    fi

    # Stage and commit
    git add -A
    git commit -m "$(cat <<EOF
${type}(#${ISSUE_NUM}): ${issue_title}

Closes #${ISSUE_NUM}

Implemented via automated ship workflow.
EOF
)"

    success "Step 4 complete: Changes committed"
}

step_5_pr() {
    info "Step 5: Create Pull Request"

    local branch=$(git branch --show-current)
    local issue_title=$(gh issue view "$ISSUE_NUM" --json title -q '.title')
    local has_bug_label=$(gh issue view "$ISSUE_NUM" --json labels -q '.labels | map(.name) | any(. == "bug")')

    local type="feat"
    if [[ "$has_bug_label" == "true" ]]; then
        type="fix"
    fi

    # Push branch
    git push -u origin HEAD

    # Create PR
    local pr_url=$(gh pr create \
        --base main \
        --title "${type}(#${ISSUE_NUM}): ${issue_title}" \
        --body "$(cat <<EOF
## Summary
Automated implementation for issue #${ISSUE_NUM}

## Related Issue
Closes #${ISSUE_NUM}

## Changes
$(git diff --stat origin/main...HEAD 2>/dev/null || echo "See commits")

---
*Generated by ship-issue.sh automation*
EOF
)" 2>&1)

    success "Step 5 complete: PR created"
    echo "$pr_url"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "🚀 Ship Issue #$ISSUE_NUM"
    info "=========================================="

    cd "$PROJECT_ROOT"

    # Pre-flight
    preflight_check

    # Execute workflow
    local branch=$(step_1_branch_setup)
    step_2_planning "$branch"
    step_3_implementation
    step_4_commit
    local pr_url=$(step_5_pr)

    # Summary
    echo ""
    echo "=========================================="
    success "🚀 SHIP COMPLETE"
    echo "=========================================="
    echo "Issue:    #$ISSUE_NUM"
    echo "Branch:   $branch"
    echo "PR:       $pr_url"
    echo "Log:      $LOG_FILE"
    echo "=========================================="
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
