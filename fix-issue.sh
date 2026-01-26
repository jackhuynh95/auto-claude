#!/bin/bash
# ==============================================================================
# Script Name: fix-issue.sh
# Description: Automates GitHub bug fix workflow via Claude CLI
#              Uses /fix loop with optional --hard mode for complex issues
#
# Usage:       ./fix-issue.sh <issue-number> [--auto] [--hard] [--codex|--opencode]
# Example:     ./fix-issue.sh 42                      # /fix loop
#              ./fix-issue.sh 42 --auto               # YOLO mode
#              ./fix-issue.sh 42 --hard               # /fix:hard for complex issues
#              ./fix-issue.sh 42 --auto --codex       # Codex fallback (GPT-5.2)
#              ./fix-issue.sh 42 --auto --opencode    # OpenCode fallback
#
# Requirements:
#   - Claude CLI installed and authenticated
#   - GitHub CLI (gh) installed and authenticated
#   - Git configured with push access
#   - (Optional) Codex CLI or OpenCode for fallback mode
#
# Environment Variables:
#   - ANTHROPIC_API_KEY: Required for Claude CLI auth
#   - GITHUB_TOKEN: Optional, for gh CLI if not logged in
#   - FIX_AUTO: Set to "true" for YOLO mode (same as --auto flag)
#   - FIX_MAX_RETRIES: Max fix attempts before fallback (default: 3)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${PROJECT_ROOT}/logs/fix-$(date +%Y%m%d-%H%M%S).log"
ISSUE_NUM="${1:-}"
MAX_RETRIES="${FIX_MAX_RETRIES:-3}"

# Parse flags
AUTO_MODE=""
HARD_MODE=""      # use /fix:hard instead of /fix
FALLBACK_TOOL=""  # "codex" or "opencode"
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_MODE="--auto" ;;
        --hard) HARD_MODE="true" ;;
        --codex) FALLBACK_TOOL="codex" ;;
        --opencode) FALLBACK_TOOL="opencode" ;;
    esac
done

# Determine fix command
FIX_CMD="/fix"
[[ "$HARD_MODE" == "true" ]] && FIX_CMD="/fix:hard"

# Cached issue data
ISSUE_JSON=""
ISSUE_TITLE=""
ISSUE_BODY=""
ISSUE_STATE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
# GitHub Issue Data
# ------------------------------------------------------------------------------

fetch_issue_data() {
    info "Fetching issue #$ISSUE_NUM data..."

    ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json title,body,state,labels)
    ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
    ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
    ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')

    success "Issue: $ISSUE_TITLE"
}

comment_issue() {
    local file="${1:-}"
    local msg="${2:-}"

    if [[ -n "$file" ]] && [[ -f "$file" ]]; then
        info "Posting comment from file..."
        gh issue comment "$ISSUE_NUM" --body-file "$file"
    elif [[ -n "$msg" ]]; then
        info "Posting comment..."
        gh issue comment "$ISSUE_NUM" --body "$msg"
    fi
}

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------

preflight_check() {
    info "Running pre-flight checks..."

    if [[ -z "$ISSUE_NUM" ]]; then
        error "Usage: $0 <issue-number> [--auto] [--hard] [--codex|--opencode]"
        exit 1
    fi

    if ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
        error "Issue number must be a positive integer"
        exit 1
    fi

    if ! command -v claude &> /dev/null; then
        error "Claude CLI not found"
        exit 1
    fi

    if ! command -v gh &> /dev/null; then
        error "GitHub CLI (gh) not found"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        error "GitHub CLI not authenticated"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        error "jq not found"
        exit 1
    fi

    # Validate fallback tool if specified
    if [[ "$FALLBACK_TOOL" == "codex" ]]; then
        if ! command -v codex &> /dev/null; then
            warn "Codex CLI not found - fallback disabled"
            FALLBACK_TOOL=""
        fi
    elif [[ "$FALLBACK_TOOL" == "opencode" ]]; then
        if ! command -v opencode &> /dev/null; then
            warn "OpenCode CLI not found - fallback disabled"
            FALLBACK_TOOL=""
        fi
    fi

    fetch_issue_data

    if [[ "$ISSUE_STATE" != "OPEN" ]]; then
        error "Issue #$ISSUE_NUM is not open (state: $ISSUE_STATE)"
        exit 1
    fi

    if [[ -n "$(git status --porcelain)" ]]; then
        warn "Stashing uncommitted changes..."
        git stash push -m "auto-stash-fix-$ISSUE_NUM"
    fi

    success "Pre-flight checks passed"
}

# ------------------------------------------------------------------------------
# Claude CLI Wrapper
# ------------------------------------------------------------------------------

run_claude() {
    local prompt="$1"
    local flags=""

    if [[ "$AUTO_MODE" == "--auto" ]] || [[ "${FIX_AUTO:-false}" == "true" ]]; then
        flags="--dangerously-skip-permissions"
        warn "YOLO mode enabled"
    fi

    info "Running Claude: ${prompt:0:80}..."

    claude -p "$prompt" $flags --continue --output-format text 2>&1 | tee -a "$LOG_FILE"
    return ${PIPESTATUS[0]}
}

# ------------------------------------------------------------------------------
# Fallback Tools (Codex / OpenCode)
# ------------------------------------------------------------------------------

run_codex() {
    local prompt="$1"

    info "Running Codex (GPT-5.2-high) fallback..."

    codex --model gpt-5.2-high --full-auto "$prompt" 2>&1 | tee -a "$LOG_FILE"
    return ${PIPESTATUS[0]}
}

run_opencode() {
    local prompt="$1"

    info "Running OpenCode fallback..."

    opencode -p "$prompt" --auto-approve 2>&1 | tee -a "$LOG_FILE"
    return ${PIPESTATUS[0]}
}

run_fallback() {
    local prompt="$1"

    case "$FALLBACK_TOOL" in
        codex) run_codex "$prompt" ;;
        opencode) run_opencode "$prompt" ;;
        *) warn "No fallback tool configured" ;;
    esac
}

# ------------------------------------------------------------------------------
# Workflow Steps
# ------------------------------------------------------------------------------

step_1_branch() {
    info "Step 1: Branch Setup"

    local slug=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
    local branch="fix/issue-${ISSUE_NUM}-${slug}"

    git checkout -b "$branch" 2>/dev/null || {
        warn "Branch exists, checking out..."
        git checkout "$branch"
    }

    success "Branch: $branch"
    echo "$branch"
}

step_2_fix_loop() {
    info "Step 2: Fix Loop using $FIX_CMD (max $MAX_RETRIES attempts)"

    local attempt=1
    local has_errors=true

    # Build issue context
    local issue_context="GitHub Issue #$ISSUE_NUM: $ISSUE_TITLE

$ISSUE_BODY"

    while [[ "$has_errors" == "true" ]] && [[ $attempt -le $MAX_RETRIES ]]; do
        info "Fix attempt $attempt/$MAX_RETRIES"

        # Run fix command with issue context
        run_claude "$FIX_CMD Fix this issue:

$issue_context"

        # Run build/tests to check for errors
        local build_output=""
        if [[ -f "package.json" ]]; then
            build_output=$(npm run build 2>&1 || true)
        elif [[ -f "Cargo.toml" ]]; then
            build_output=$(cargo build 2>&1 || true)
        elif [[ -f "go.mod" ]]; then
            build_output=$(go build ./... 2>&1 || true)
        fi

        # Check for errors
        if echo "$build_output" | grep -qi "error\|failed\|exception"; then
            warn "Errors remain after fix attempt $attempt"

            local error_snippet=$(echo "$build_output" | grep -i "error\|failed" | head -20)
            issue_context="Build errors after fix attempt:

$error_snippet

Original issue: $ISSUE_TITLE"

            ((attempt++))
        else
            success "No build errors - fix successful"
            has_errors=false
        fi
    done

    if [[ "$has_errors" == "true" ]]; then
        warn "Max retries reached with errors remaining"

        if [[ -n "$FALLBACK_TOOL" ]]; then
            step_2b_fallback
        else
            warn "Consider using --codex or --opencode flag for fallback"
        fi
    fi
}

step_2b_fallback() {
    info "Step 2b: Fallback ($FALLBACK_TOOL)"

    run_fallback "Fix the remaining build errors in this project. The issue being fixed is #$ISSUE_NUM: $ISSUE_TITLE"

    success "Fallback ($FALLBACK_TOOL) complete"
}

step_3_post_reports() {
    info "Step 3: Post Reports"

    local app_reports=$(find ./apps -type f -iname "*report*.md" 2>/dev/null || true)

    if [[ -z "$app_reports" ]]; then
        info "No reports found"
        return 0
    fi

    while IFS= read -r report; do
        if [[ -f "$report" ]]; then
            comment_issue "$report"
            rm -f "$report"
        fi
    done <<< "$app_reports"

    success "Reports posted"
}

step_4_commit() {
    info "Step 4: Commit"

    if [[ -z "$(git status --porcelain)" ]]; then
        warn "No changes to commit"
        return 0
    fi

    git add -A
    git commit -m "$(cat <<EOF
fix(#${ISSUE_NUM}): ${ISSUE_TITLE}

Refs #${ISSUE_NUM}

Automated fix via fix-issue.sh
EOF
)"

    success "Changes committed"
}

step_5_pr() {
    info "Step 5: Create PR"

    local branch=$(git branch --show-current)

    git push -u origin HEAD

    local pr_url=$(gh pr create \
        --base main \
        --title "fix(#${ISSUE_NUM}): ${ISSUE_TITLE}" \
        --body "$(cat <<EOF
## Summary
Automated bug fix for issue #${ISSUE_NUM}

## Related Issue
Closes #${ISSUE_NUM}

## Changes
$(git diff --stat origin/main...HEAD 2>/dev/null || echo "See commits")

---
*Generated by fix-issue.sh*
EOF
)" 2>&1)

    info "Adding 'shipped' label..."
    gh issue edit "$ISSUE_NUM" --add-label "shipped" 2>/dev/null || {
        gh label create "shipped" --description "Fix shipped, awaiting verification" --color "7057ff" 2>/dev/null || true
        gh issue edit "$ISSUE_NUM" --add-label "shipped"
    }

    success "PR created"
    echo "$pr_url"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "Fix Issue #$ISSUE_NUM"
    info "Command: $FIX_CMD"
    info "=========================================="

    cd "$PROJECT_ROOT"

    preflight_check

    local branch=$(step_1_branch)
    step_2_fix_loop
    step_3_post_reports
    step_4_commit
    local pr_url=$(step_5_pr)

    echo ""
    echo "=========================================="
    success "FIX COMPLETE"
    echo "=========================================="
    echo "Issue:    #$ISSUE_NUM"
    echo "Branch:   $branch"
    echo "PR:       $pr_url"
    echo "Log:      $LOG_FILE"
    echo "=========================================="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
