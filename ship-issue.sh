#!/bin/bash
# ==============================================================================
# Script Name: ship-issue.sh
# Description: Automates GitHub issue → Plan → Code → PR workflow via Claude CLI
#              Designed for CI/CD pipelines and headless automation
#
# Usage:       ./ship-issue.sh <issue-number> [--auto]
# Example:     ./ship-issue.sh 42
#              ./ship-issue.sh 42 --auto  # YOLO mode
#
# Requirements:
#   - Claude CLI installed and authenticated
#   - GitHub CLI (gh) installed and authenticated
#   - Git configured with push access
#
# Environment Variables:
#   - ANTHROPIC_API_KEY: Required for Claude CLI auth
#   - GITHUB_TOKEN: Optional, for gh CLI if not logged in
#   - SHIP_AUTO: Set to "true" for YOLO mode (same as --auto flag)
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

# Cached issue data (populated by fetch_issue_data)
ISSUE_JSON=""
ISSUE_TITLE=""
ISSUE_BODY=""
ISSUE_STATE=""
ISSUE_TYPE=""  # "feat" or "fix"

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
# GitHub Issue Data (single API call, reuse with jq)
# ------------------------------------------------------------------------------

fetch_issue_data() {
    info "Fetching issue #$ISSUE_NUM data..."

    # Single API call - fetch all needed fields
    ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json title,body,state,labels)

    # Extract fields with jq
    ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
    ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
    ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')

    # Determine type: fix for bugs, feat for others
    local has_bug=$(echo "$ISSUE_JSON" | jq -r '.labels | map(.name) | any(. == "bug")')
    if [[ "$has_bug" == "true" ]]; then
        ISSUE_TYPE="fix"
    else
        ISSUE_TYPE="feat"
    fi

    success "Issue data cached (title: $ISSUE_TITLE, type: $ISSUE_TYPE)"
}

# ------------------------------------------------------------------------------
# GitHub Issue Commenting
# ------------------------------------------------------------------------------

comment_issue() {
    local file="${1:-}"
    local msg="${2:-}"

    if [[ -n "$file" ]] && [[ -f "$file" ]]; then
        info "Posting comment from file to issue #$ISSUE_NUM..."
        gh issue comment "$ISSUE_NUM" --body-file "$file"
        success "Comment posted to issue #$ISSUE_NUM"
    elif [[ -n "$msg" ]]; then
        info "Posting comment to issue #$ISSUE_NUM..."
        gh issue comment "$ISSUE_NUM" --body "$msg"
        success "Comment posted to issue #$ISSUE_NUM"
    else
        warn "No file or message provided for comment"
    fi
}

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

    # Check jq
    if ! command -v jq &> /dev/null; then
        error "jq not found. Install it first (brew install jq)."
        exit 1
    fi

    # Fetch and cache issue data (single API call)
    fetch_issue_data

    # Check issue is open
    if [[ "$ISSUE_STATE" != "OPEN" ]]; then
        error "Issue #$ISSUE_NUM is not open (state: $ISSUE_STATE)"
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

    # Use cached issue data (no API call)
    local slug=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
    local branch="${ISSUE_TYPE}/issue-${ISSUE_NUM}-${slug}"

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

    # Use cached issue data (no API call)
    local issue_content="${ISSUE_TITLE}

${ISSUE_BODY}"

    # Run planning command via Claude
    run_claude "/plan:fast Implement GitHub issue #$ISSUE_NUM:

$issue_content

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
    run_claude "/code:auto $plan_path"

    success "Step 3 complete: Implementation done"
}

step_3b_post_reports() {
    info "Step 3b: Post Reports to Issue"

    # Only scan apps/**/*report*.md (temporary test reports)
    # Skip plans/reports/*.md (permanent documentation - don't delete)
    local app_reports=$(find ./apps -type f -iname "*report*.md" 2>/dev/null || true)

    if [[ -z "$app_reports" ]]; then
        info "No report files found in apps/"
        return 0
    fi

    # Post each report as a comment, then delete
    while IFS= read -r report; do
        if [[ -f "$report" ]]; then
            info "Found report: $report"
            comment_issue "$report"
            # Cleanup: remove after posting
            info "Removing: $report"
            rm -f "$report"
        fi
    done <<< "$app_reports"

    success "Reports posted and cleaned up"
}

step_4_commit() {
    info "Step 4: Commit Changes"

    # Check if there are changes to commit
    if [[ -z "$(git status --porcelain)" ]]; then
        warn "No changes to commit"
        return 0
    fi

    # Use cached issue data (no API call)
    # Stage and commit (no "Closes" - issue stays open for manual review)
    git add -A
    git commit -m "$(cat <<EOF
${ISSUE_TYPE}(#${ISSUE_NUM}): ${ISSUE_TITLE}

Refs #${ISSUE_NUM}

Implemented via automated ship workflow.
EOF
)"

    success "Step 4 complete: Changes committed"
}

step_5_pr() {
    info "Step 5: Create Pull Request"

    # Use cached issue data (no API call)
    local branch=$(git branch --show-current)

    # Push branch
    git push -u origin HEAD

    # Create PR (no "Closes" - issue stays open for manual review)
    local pr_url=$(gh pr create \
        --base main \
        --title "${ISSUE_TYPE}(#${ISSUE_NUM}): ${ISSUE_TITLE}" \
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

    # Add 'shipped' label to issue (keeps issue open for manual testing)
    info "Adding 'shipped' label to issue #$ISSUE_NUM..."
    gh issue edit "$ISSUE_NUM" --add-label "shipped" 2>/dev/null || {
        warn "Could not add 'shipped' label (may not exist). Creating it..."
        gh label create "shipped" --description "Implementation complete, awaiting verification" --color "7057ff" 2>/dev/null || true
        gh issue edit "$ISSUE_NUM" --add-label "shipped"
    }

    success "Step 5 complete: PR created, issue labeled as 'shipped'"
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
    step_3b_post_reports  # Post reports then delete before commit
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
