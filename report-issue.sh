#!/bin/bash
# ==============================================================================
# Script: report-issue.sh
# Description: Post-fix/ship Slack reporting for pipeline issues.
#              Gathers issue context, PR status, and sends to Slack
#              via claude -p "/slack-report ..." (same as ship-issue uses /code:auto).
#              Fallback: clipboard + open Slack.
#
# Usage:       ./report-issue.sh <issue-number> [flags...]
# Example:     ./report-issue.sh 42
#              ./report-issue.sh 42 --auto          # skip Claude permissions
#              ./report-issue.sh 42 --dry-run
#              ./report-issue.sh 42 --clipboard     # copy to clipboard only
#
# Designed to be called by looper.sh, fix-issue.sh, or ship-issue.sh
# after successful PR creation.
#
# Requirements:
#   - Claude CLI installed and authenticated (for /slack-report skill)
#   - GitHub CLI (gh) installed and authenticated
#   - jq for JSON processing
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/report-$(date +%Y%m%d-%H%M%S).log"
ISSUE_NUM="${1:-}"

# Defaults
DRY_RUN=""
CLIPBOARD_ONLY=""
AUTO_MODE=""
CHANNEL="#medusa-agent-swarm"

# Parse flags
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    case "${ARGS[$i]}" in
        --dry-run) DRY_RUN="true" ;;
        --clipboard) CLIPBOARD_ONLY="true" ;;
        --auto) AUTO_MODE="true" ;;
        --channel)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && CHANNEL="${ARGS[$((i+1))]}"
            ;;
        [0-9]*) ;; # skip issue number
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$LOG_DIR"

log() { echo -e "[$1] $2" | tee -a "$LOG_FILE"; }
info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "OK" "${GREEN}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

if [[ -z "$ISSUE_NUM" ]] || ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
    error "Usage: $0 <issue-number> [--dry-run] [--clipboard] [--channel <channel>]"
    exit 1
fi

for cmd in gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required: $cmd"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Gather issue context
# ------------------------------------------------------------------------------

info "Gathering context for issue #${ISSUE_NUM}..."

# Fetch issue details
ISSUE_JSON="$(gh issue view "$ISSUE_NUM" --json title,state,labels,body,closedAt 2>/dev/null || true)"
[[ -z "$ISSUE_JSON" ]] && ISSUE_JSON="{}"
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // "Unknown"')
ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state // "UNKNOWN"')
ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[]?.name] | join(", ") // "none"')

# Determine issue type from title prefix
ISSUE_TYPE="unknown"
UPPER_TITLE=$(echo "$ISSUE_TITLE" | tr '[:lower:]' '[:upper:]')
case "$UPPER_TITLE" in
    *"[BUG]"*)         ISSUE_TYPE="bug fix" ;;
    *"[FEATURE]"*)     ISSUE_TYPE="feature" ;;
    *"[ENHANCEMENT]"*) ISSUE_TYPE="enhancement" ;;
    *"[CHORE]"*)       ISSUE_TYPE="chore" ;;
    *"[DOCS]"*)        ISSUE_TYPE="docs" ;;
esac

# Find associated PR
PR_JSON=$(gh pr list --search "issue:${ISSUE_NUM}" --json number,title,url,state,headRefName --limit 1 2>/dev/null || echo "[]")
PR_COUNT=$(echo "$PR_JSON" | jq 'length')

PR_INFO=""
if [[ "$PR_COUNT" -gt 0 ]]; then
    PR_NUM=$(echo "$PR_JSON" | jq -r '.[0].number')
    PR_URL=$(echo "$PR_JSON" | jq -r '.[0].url')
    PR_STATE=$(echo "$PR_JSON" | jq -r '.[0].state')
    PR_BRANCH=$(echo "$PR_JSON" | jq -r '.[0].headRefName')
    PR_INFO="PR #${PR_NUM} (${PR_STATE}) — ${PR_URL}"
else
    # Fallback: search by branch naming convention
    PR_JSON=$(gh pr list --head "fix-issue-${ISSUE_NUM}" --json number,url,state --limit 1 2>/dev/null || echo "[]")
    if [[ $(echo "$PR_JSON" | jq 'length') -gt 0 ]]; then
        PR_NUM=$(echo "$PR_JSON" | jq -r '.[0].number')
        PR_URL=$(echo "$PR_JSON" | jq -r '.[0].url')
        PR_STATE=$(echo "$PR_JSON" | jq -r '.[0].state')
        PR_INFO="PR #${PR_NUM} (${PR_STATE}) — ${PR_URL}"
    else
        PR_INFO="No PR found"
    fi
fi

# Check current pipeline label
CURRENT_STAGE="unknown"
if echo "$ISSUE_LABELS" | grep -q "verified"; then
    CURRENT_STAGE="verified"
elif echo "$ISSUE_LABELS" | grep -q "ready_for_test"; then
    CURRENT_STAGE="ready_for_test"
elif echo "$ISSUE_LABELS" | grep -q "shipped"; then
    CURRENT_STAGE="shipped"
elif echo "$ISSUE_LABELS" | grep -q "ready_for_dev"; then
    CURRENT_STAGE="ready_for_dev"
fi

# Pick status emoji
STATUS_EMOJI="🔧"
case "$CURRENT_STAGE" in
    verified)       STATUS_EMOJI="✅" ;;
    ready_for_test) STATUS_EMOJI="🧪" ;;
    shipped)        STATUS_EMOJI="🚀" ;;
    ready_for_dev)  STATUS_EMOJI="🔄" ;;
esac

# ------------------------------------------------------------------------------
# Extract executive summary from latest fix/ship log
# ------------------------------------------------------------------------------

EXEC_SUMMARY=""

# Find latest log for this issue (fix-*.log, ship-*.log, or .md variants)
LATEST_LOG=$(ls -t "${LOG_DIR}"/fix-*.log "${LOG_DIR}"/fix-*.md "${LOG_DIR}"/ship-*.log "${LOG_DIR}"/ship-*.md 2>/dev/null | head -1 || true)

if [[ -n "$LATEST_LOG" ]] && [[ -f "$LATEST_LOG" ]]; then
    info "Found execution log: $LATEST_LOG"
    # Extract last 50 lines — the summary/result section
    EXEC_SUMMARY=$(tail -50 "$LATEST_LOG" 2>/dev/null | head -30)
fi

# ------------------------------------------------------------------------------
# Build context for /slack-report
# ------------------------------------------------------------------------------

CONTEXT="${STATUS_EMOJI} Issue #${ISSUE_NUM} — ${ISSUE_TITLE}
Type: ${ISSUE_TYPE} | Stage: ${CURRENT_STAGE}
${PR_INFO}
Labels: ${ISSUE_LABELS}"

if [[ -n "$EXEC_SUMMARY" ]]; then
    CONTEXT="${CONTEXT}

--- Execution Log (last run) ---
${EXEC_SUMMARY}"
fi

info "Context preview:"
echo ""
echo "$CONTEXT"
echo ""

# ------------------------------------------------------------------------------
# Deliver: claude -p "/slack-report ..." → clipboard fallback
# Same pattern as ship-issue.sh uses claude -p "/code:auto ..."
# ------------------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would send via /slack-report to ${CHANNEL}:"
    echo "$CONTEXT"
    exit 0
fi

if [[ "$CLIPBOARD_ONLY" == "true" ]]; then
    echo "$CONTEXT" | pbcopy
    success "Report copied to clipboard."
    exit 0
fi

# Build claude flags
CLAUDE_FLAGS="--model haiku --output-format text"
[[ "$AUTO_MODE" == "true" ]] && CLAUDE_FLAGS="$CLAUDE_FLAGS --dangerously-skip-permissions"

# claude -p "/slack-report ..." — Claude reads context, generates report, sends via skill
if command -v claude &>/dev/null; then
    info "Sending via claude /slack-report to ${CHANNEL}..."
    if claude -p "/slack-report ${CONTEXT}" $CLAUDE_FLAGS 2>&1 | tee -a "$LOG_FILE"; then
        success "Report sent to ${CHANNEL}"
    else
        warn "/slack-report failed — falling back to clipboard"
        echo "$CONTEXT" | pbcopy
        open -a Slack 2>/dev/null || true
        success "Report copied to clipboard. Paste in ${CHANNEL}."
    fi
else
    warn "Claude CLI not available"
    echo "$CONTEXT" | pbcopy
    open -a Slack 2>/dev/null || true
    success "Report copied to clipboard. Paste in ${CHANNEL}."
fi

info "Report logged to: $LOG_FILE"
