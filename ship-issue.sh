#!/bin/bash
# ==============================================================================
# Script Name: ship-issue.sh
# Description: Automates GitHub issue → Plan → Code → PR workflow via Claude CLI
#              Designed for CI/CD pipelines and headless automation
#
# Usage:       ./ship-issue.sh <issue-number> [flags...]
# Example:     ./ship-issue.sh 42
#              ./ship-issue.sh 42 --auto                   # YOLO mode
#              ./ship-issue.sh 42 --auto --worktree        # isolated git worktree
#              ./ship-issue.sh 42 --auto --e2e             # ship then e2e verify
#              ./ship-issue.sh 42 --e2e-only               # e2e test only (no ship)
#              ./ship-issue.sh 42 --frontend-design        # ship then UI review
#              ./ship-issue.sh 42 --frontend-design-only   # UI review only
#              ./ship-issue.sh 42 --model opus             # force model
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

# Parse flags
AUTO_MODE=""
WORKTREE_MODE=""
E2E_MODE=""
E2E_ONLY=""
FRONTEND_DESIGN=""
FRONTEND_DESIGN_ONLY=""
MODEL_OVERRIDE=""

for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_MODE="--auto" ;;
        --worktree) WORKTREE_MODE="true" ;;
        --e2e) E2E_MODE="true" ;;
        --e2e-only) E2E_ONLY="true" ;;
        --frontend-design) FRONTEND_DESIGN="true" ;;
        --frontend-design-only) FRONTEND_DESIGN_ONLY="true" ;;
        --model) ;; # value handled below
    esac
done

# Parse --model value (needs lookahead)
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "--model" ]] && [[ -n "${ARGS[$((i+1))]:-}" ]]; then
        MODEL_OVERRIDE="${ARGS[$((i+1))]}"
    fi
done

# Determine model: default sonnet for ship, opus available via override
if [[ -n "$MODEL_OVERRIDE" ]]; then
    MODEL_FLAG="--model $MODEL_OVERRIDE"
else
    MODEL_FLAG="--model sonnet"
fi

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

    info "Executing Claude ($MODEL_FLAG)..."

    claude -p "$prompt" $flags $MODEL_FLAG --continue --output-format text 2>&1 | tee -a "$LOG_FILE"

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

    if [[ "$WORKTREE_MODE" == "true" ]]; then
        WORKTREE_DIR="/tmp/ship-issue-${ISSUE_NUM}"
        info "Creating worktree at $WORKTREE_DIR"

        # Clean up existing worktree if present
        if [[ -d "$WORKTREE_DIR" ]]; then
            warn "Worktree exists, removing..."
            git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
            git branch -D "$branch" 2>/dev/null || true
        fi

        git worktree add "$WORKTREE_DIR" -b "$branch" 2>/dev/null || {
            git branch -D "$branch" 2>/dev/null || true
            git worktree add "$WORKTREE_DIR" -b "$branch"
        }

        cd "$WORKTREE_DIR"
        success "Step 1 complete: Worktree $WORKTREE_DIR (branch: $branch)"
    else
        git checkout -b "$branch" 2>/dev/null || {
            warn "Branch $branch already exists, checking out..."
            git checkout "$branch"
        }
        success "Step 1 complete: Branch $branch"
    fi

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
# E2E Verification
# ------------------------------------------------------------------------------

step_e2e() {
    info "E2E Verification"

    if command -v curl &> /dev/null; then
        curl -sf http://localhost:9000/health > /dev/null 2>&1 || {
            warn "Medusa API not running at localhost:9000 - skipping e2e"
            return 1
        }
    fi

    run_claude "Run e2e-test scenarios to verify fix for issue #$ISSUE_NUM: $ISSUE_TITLE.
Use the e2e-test skill. Run these scenarios: create-account, purchase-success.
Report pass/fail."

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        success "E2E tests passed"
        return 0
    else
        warn "E2E tests failed"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Frontend Design Review
# ------------------------------------------------------------------------------

step_frontend_design() {
    info "Frontend Design Review"

    run_claude "Use the frontend-design skill to review the UI changes for issue #$ISSUE_NUM: $ISSUE_TITLE.
Take screenshots and report any design issues. Do not auto-fix."

    comment_issue "" "**Frontend Design Review** for #$ISSUE_NUM completed. Check logs for details."
    success "Frontend design review complete"
}

# ------------------------------------------------------------------------------
# Worktree Cleanup
# ------------------------------------------------------------------------------

cleanup_worktree() {
    if [[ "$WORKTREE_MODE" == "true" ]] && [[ -n "${WORKTREE_DIR:-}" ]]; then
        info "Cleaning up worktree..."
        cd "$PROJECT_ROOT"
        git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || {
            warn "Failed to remove worktree at $WORKTREE_DIR (manual cleanup needed)"
        }
        success "Worktree cleaned up"
    fi
}

# ------------------------------------------------------------------------------
# Label Transitions
# ------------------------------------------------------------------------------

transition_label() {
    local remove_label="$1"
    local add_label="$2"

    if [[ -n "$remove_label" ]]; then
        gh issue edit "$ISSUE_NUM" --remove-label "$remove_label" 2>/dev/null || true
    fi
    if [[ -n "$add_label" ]]; then
        gh issue edit "$ISSUE_NUM" --add-label "$add_label" 2>/dev/null || true
    fi
    info "Label transition: -$remove_label +$add_label"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "Ship Issue #$ISSUE_NUM"
    info "Model: ${MODEL_FLAG:-sonnet (default)}"
    [[ "$WORKTREE_MODE" == "true" ]] && info "Mode: worktree"
    [[ "$E2E_MODE" == "true" ]] && info "Post-ship: e2e"
    [[ "$E2E_ONLY" == "true" ]] && info "Mode: e2e-only"
    [[ "$FRONTEND_DESIGN" == "true" ]] && info "Post-ship: frontend-design"
    [[ "$FRONTEND_DESIGN_ONLY" == "true" ]] && info "Mode: frontend-design-only"
    info "=========================================="

    cd "$PROJECT_ROOT"

    # Pre-flight
    preflight_check

    # --- E2E-only mode: skip ship, just test ---
    if [[ "$E2E_ONLY" == "true" ]]; then
        if step_e2e; then
            transition_label "ready_for_test" "verified"
            success "E2E passed — issue verified"
        else
            transition_label "ready_for_test" "ready_for_dev"
            warn "E2E failed — re-queued for dev"
        fi
        return
    fi

    # --- Frontend-design-only mode ---
    if [[ "$FRONTEND_DESIGN_ONLY" == "true" ]]; then
        step_frontend_design
        return
    fi

    # --- Standard ship flow ---
    local branch=$(step_1_branch_setup)
    step_2_planning "$branch"
    step_3_implementation

    # E2E after implementation (gates PR creation)
    if [[ "$E2E_MODE" == "true" ]]; then
        if ! step_e2e; then
            warn "E2E failed — skipping PR creation"
            cleanup_worktree
            return
        fi
    fi

    # Frontend design review (report only, doesn't gate PR)
    if [[ "$FRONTEND_DESIGN" == "true" ]]; then
        step_frontend_design
    fi

    step_3b_post_reports
    step_4_commit
    local pr_url=$(step_5_pr)

    # Transition label after PR
    transition_label "ready_for_dev" "ready_for_test"

    cleanup_worktree

    # Summary
    echo ""
    echo "=========================================="
    success "SHIP COMPLETE"
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
