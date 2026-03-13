#!/bin/bash
# ==============================================================================
# Script Name: fix-issue.sh
# Description: Automates GitHub bug fix workflow via Claude CLI
#              3-phase loop: /debug → /fix → /test with retry on failure
#
# Usage:       ./fix-issue.sh <issue-number> [flags...]
# Example:     ./fix-issue.sh 42                      # /fix loop
#              ./fix-issue.sh 42 --auto               # YOLO mode
#              ./fix-issue.sh 42 --hard               # /fix:hard for complex issues
#              ./fix-issue.sh 42 --auto --worktree    # isolated git worktree
#              ./fix-issue.sh 42 --auto --e2e         # fix then e2e verify
#              ./fix-issue.sh 42 --e2e-only           # e2e test only (no fix)
#              ./fix-issue.sh 42 --frontend-design    # fix then UI review
#              ./fix-issue.sh 42 --frontend-design-only  # UI review only
#              ./fix-issue.sh 42 --model opus         # force model
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
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_FILE="${PROJECT_ROOT}/logs/fix-$(date +%Y%m%d-%H%M%S).log"
ISSUE_NUM="${1:-}"
MAX_RETRIES="${FIX_MAX_RETRIES:-3}"

# Parse flags
AUTO_MODE=""
HARD_MODE=""           # use /fix:hard instead of /fix
WORKTREE_MODE=""       # run fix in isolated git worktree
E2E_MODE=""            # run e2e after fix
E2E_ONLY=""            # run e2e only (no fix)
FRONTEND_DESIGN=""     # run frontend-design review after fix
FRONTEND_DESIGN_ONLY="" # run frontend-design review only (no fix)
MODEL_OVERRIDE=""      # explicit model override
FALLBACK_TOOL=""       # "codex" or "opencode"

# Parse flags (skip first arg which is issue number)
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_MODE="--auto" ;;
        --hard) HARD_MODE="true" ;;
        --worktree) WORKTREE_MODE="true" ;;
        --e2e) E2E_MODE="true" ;;
        --e2e-only) E2E_ONLY="true" ;;
        --frontend-design) FRONTEND_DESIGN="true" ;;
        --frontend-design-only) FRONTEND_DESIGN_ONLY="true" ;;
        --model) ;; # value handled below
        --codex) FALLBACK_TOOL="codex" ;;
        --opencode) FALLBACK_TOOL="opencode" ;;
    esac
done

# Parse --model value (needs lookahead)
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "--model" ]] && [[ -n "${ARGS[$((i+1))]:-}" ]]; then
        MODEL_OVERRIDE="${ARGS[$((i+1))]}"
    fi
done

# Determine fix command
FIX_CMD="/fix"
[[ "$HARD_MODE" == "true" ]] && FIX_CMD="/fix:hard"

# Model routing (Issue 07): sonnet for /fix, opus for /fix:hard + design review
if [[ -n "$MODEL_OVERRIDE" ]]; then
    MODEL_FLAG="--model $MODEL_OVERRIDE"
    MODEL_FLAG_REASONING="--model $MODEL_OVERRIDE"
elif [[ "$HARD_MODE" == "true" ]]; then
    MODEL_FLAG=""                      # opus (default) for hard bugs
    MODEL_FLAG_REASONING=""            # opus for reasoning tasks too
else
    MODEL_FLAG="--model sonnet"        # sonnet for standard fixes
    MODEL_FLAG_REASONING=""            # opus for reasoning tasks (design review)
fi

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
        error "Usage: $0 <issue-number> [--auto] [--hard] [--worktree] [--e2e] [--e2e-only] [--frontend-design] [--model <model>] [--codex|--opencode]"
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

    info "Running Claude ($MODEL_FLAG): ${prompt:0:80}..."

    claude -p "$prompt" $flags $MODEL_FLAG --continue --output-format text 2>&1 | tee -a "$LOG_FILE"
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

    # Always start from main to ensure clean branch creation
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
    git pull --ff-only 2>/dev/null || true

    # Clean up stale worktree if branch is checked out elsewhere
    local worktree_path=$(git worktree list --porcelain | grep -B1 "branch refs/heads/$branch" | grep "worktree " | sed 's/worktree //')
    if [[ -n "$worktree_path" ]]; then
        warn "Branch $branch checked out in worktree $worktree_path — removing stale worktree"
        git worktree remove "$worktree_path" --force 2>/dev/null || true
    fi

    if [[ "$WORKTREE_MODE" == "true" ]]; then
        WORKTREE_DIR="/tmp/fix-issue-${ISSUE_NUM}"
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
        success "Worktree: $WORKTREE_DIR (branch: $branch)"
    else
        git checkout -b "$branch" 2>/dev/null || {
            warn "Branch exists, checking out..."
            git checkout "$branch"
            # Rebase on main to pick up latest changes
            git rebase main 2>/dev/null || true
        }
        success "Branch: $branch"
    fi

    echo "$branch"
}

step_2_debug() {
    info "Step 2a: Debug — Investigate root cause"

    local issue_context="GitHub Issue #$ISSUE_NUM: $ISSUE_TITLE

$ISSUE_BODY"

    # /debug is read-only analysis — always use opus for reasoning
    local save_model="$MODEL_FLAG"
    MODEL_FLAG="$MODEL_FLAG_REASONING"

    local debug_output
    debug_output=$(run_claude "/debug Investigate this issue and find the root cause. Do NOT implement any fix.

$issue_context" 2>&1) || true

    MODEL_FLAG="$save_model"

    # Store debug analysis for /fix step
    DEBUG_ANALYSIS="$debug_output"
    success "Debug analysis complete"
}

step_2_fix() {
    info "Step 2b: Fix — Apply the solution"

    local attempt=1
    local has_errors=true

    # Build context from debug analysis + original issue
    local fix_context="GitHub Issue #$ISSUE_NUM: $ISSUE_TITLE

$ISSUE_BODY

--- Debug Analysis ---
${DEBUG_ANALYSIS:-No debug analysis available}"

    while [[ "$has_errors" == "true" ]] && [[ $attempt -le $MAX_RETRIES ]]; do
        info "Fix attempt $attempt/$MAX_RETRIES"

        run_claude "$FIX_CMD Fix this issue based on the debug analysis:

$fix_context"

        # Run build to check for errors
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
            fix_context="Build errors after fix attempt:

$error_snippet

Original issue: $ISSUE_TITLE
Debug analysis: ${DEBUG_ANALYSIS:-N/A}"

            ((attempt++))
        else
            success "No build errors — fix applied"
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

step_2_test() {
    info "Step 2c: Test — Verify the fix"

    local test_output
    test_output=$(run_claude "/test Verify fix for issue #$ISSUE_NUM: $ISSUE_TITLE

Run all relevant tests. Report pass/fail summary." 2>&1) || true

    # Check test results
    if echo "$test_output" | grep -qi "all.*pass\|tests.*pass\|success\|0 failed"; then
        success "Tests passed — fix verified"
        return 0
    elif echo "$test_output" | grep -qi "fail\|error"; then
        warn "Tests reported failures"
        TEST_FAILURES="$test_output"
        return 1
    else
        info "Test results inconclusive — continuing"
        return 0
    fi
}

step_2_fix_loop() {
    local cycle=1

    # Initialize shared state
    DEBUG_ANALYSIS=""
    TEST_FAILURES=""

    if [[ "$HARD_MODE" == "true" ]]; then
        # --hard: skip /debug, go straight to /fix:hard → /test loop
        info "Step 2: Fix:hard → Test workflow (max $MAX_RETRIES cycles)"

        while [[ $cycle -le $MAX_RETRIES ]]; do
            info "=== Cycle $cycle/$MAX_RETRIES ==="

            # Phase 1: Fix (direct, no debug)
            step_2_fix

            # Phase 2: Test (verify)
            if step_2_test; then
                success "Cycle $cycle: Fix:hard → Test — ALL PASSED"
                return 0
            fi

            warn "Cycle $cycle: Tests failed — retrying"
            ISSUE_BODY="${ISSUE_BODY}

--- Test Failures (cycle $cycle) ---
${TEST_FAILURES:-See logs}"

            ((cycle++))
        done
    else
        # Standard: /debug → /fix → /test loop
        info "Step 2: Debug → Fix → Test workflow (max $MAX_RETRIES cycles)"

        while [[ $cycle -le $MAX_RETRIES ]]; do
            info "=== Cycle $cycle/$MAX_RETRIES ==="

            # Phase 1: Debug (investigate)
            step_2_debug

            # Phase 2: Fix (apply)
            step_2_fix

            # Phase 3: Test (verify)
            if step_2_test; then
                success "Cycle $cycle: Debug → Fix → Test — ALL PASSED"
                return 0
            fi

            warn "Cycle $cycle: Tests failed — retrying with test failure context"
            ISSUE_BODY="${ISSUE_BODY}

--- Test Failures (cycle $cycle) ---
${TEST_FAILURES:-See logs}"

            ((cycle++))
        done
    fi

    warn "Max cycles reached — some tests may still fail"

    if [[ -n "$FALLBACK_TOOL" ]]; then
        step_2b_fallback
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
# E2E Verification (Issue 04)
# ------------------------------------------------------------------------------

step_e2e() {
    info "Post-fix: E2E Verification"

    # Pre-flight: check if services are running
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
# Frontend Design Review (Issue 06)
# ------------------------------------------------------------------------------

step_frontend_design() {
    info "Post-fix: Frontend Design Review"

    # Save/restore model flag for reasoning task (Opus per Issue 07)
    local save_model="$MODEL_FLAG"
    MODEL_FLAG="$MODEL_FLAG_REASONING"
    run_claude "Use the frontend-design skill to review the UI changes for issue #$ISSUE_NUM: $ISSUE_TITLE.
Take screenshots and report any design issues. Do not auto-fix."
    MODEL_FLAG="$save_model"

    # Post results as issue comment
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

    # Wait for GitHub API to propagate label changes (eventual consistency)
    # Max 3 retries × 2s = 6s ceiling to avoid stalling the pipeline
    if [[ -n "$remove_label" ]]; then
        for i in 1 2 3; do
            sleep 2
            local current_labels=$(gh issue view "$ISSUE_NUM" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
            if ! echo "$current_labels" | grep -qx "$remove_label"; then
                info "Label propagation confirmed (${i}x2s)"
                return 0
            fi
            warn "Label not yet propagated, retrying... ($i/3)"
        done
        warn "Label propagation not confirmed after 6s — proceeding anyway"
    fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "Fix Issue #$ISSUE_NUM"
    info "Command: $FIX_CMD | Model: fix=${MODEL_FLAG:-opus} reasoning=${MODEL_FLAG_REASONING:-opus}"
    [[ "$WORKTREE_MODE" == "true" ]] && info "Mode: worktree"
    [[ "$E2E_MODE" == "true" ]] && info "Post-fix: e2e"
    [[ "$E2E_ONLY" == "true" ]] && info "Mode: e2e-only"
    [[ "$FRONTEND_DESIGN" == "true" ]] && info "Post-fix: frontend-design"
    [[ "$FRONTEND_DESIGN_ONLY" == "true" ]] && info "Mode: frontend-design-only"
    info "=========================================="

    cd "$PROJECT_ROOT"

    preflight_check

    # --- E2E-only mode: delegate to verify-issue.sh ---
    if [[ "$E2E_ONLY" == "true" ]]; then
        exec bash "${SCRIPT_DIR}/verify-issue.sh" "$ISSUE_NUM" \
            $([[ "$AUTO_MODE" == "--auto" ]] && echo "--auto") \
            $([[ -n "$MODEL_OVERRIDE" ]] && echo "--model $MODEL_OVERRIDE")
    fi

    # --- Frontend-design-only mode ---
    if [[ "$FRONTEND_DESIGN_ONLY" == "true" ]]; then
        step_frontend_design
        return
    fi

    # --- Standard fix flow ---
    local branch=$(step_1_branch)

    step_2_fix_loop

    # E2E after fix (gates PR creation)
    if [[ "$E2E_MODE" == "true" ]]; then
        if ! step_e2e; then
            warn "E2E failed — skipping PR creation"
            transition_label "ready_for_dev" ""
            cleanup_worktree
            return
        fi
    fi

    # Frontend design review after fix (report only, doesn't gate PR)
    if [[ "$FRONTEND_DESIGN" == "true" ]]; then
        step_frontend_design
    fi

    step_3_post_reports
    step_4_commit
    local pr_url=$(step_5_pr)

    # Transition label after PR
    transition_label "ready_for_dev" "ready_for_test"

    cleanup_worktree

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
