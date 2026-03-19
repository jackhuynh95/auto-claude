#!/bin/bash
# ==============================================================================
# Script: read-issue.sh
# Description: Reads Slack messages via claude /slack-read skill, outputs task
#              summary as todo list, and posts summary via /slack-report.
#              Does NOT brainstorm — looper --brainstorm-prd handles that.
#
# Usage:       ./read-issue.sh --channel "#medusa" --since "09:00" --before "10:02"
#              ./read-issue.sh --channel "#medusa" --counter 2
#              ./read-issue.sh --auto
#              ./read-issue.sh --dry-run
#
# Flow:  claude /slack-read → task summary → claude /slack-report
#
# Requirements:
#   - Claude CLI installed and authenticated
#   - slack-read skill available at .claude/skills/slack-read/
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/read-issue-$(date +%Y%m%d-%H%M%S).log"

# Defaults
DRY_RUN=""
AUTO_MODE=""
CHANNEL="#medusa-agent-swarm"
SINCE=""
BEFORE=""
COUNTER=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$LOG_DIR"

log() { echo -e "[$1] $2" | tee -a "$LOG_FILE" >&2; }
info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "OK" "${GREEN}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

ARGS=("$@")
for i in "${!ARGS[@]}"; do
    case "${ARGS[$i]}" in
        --dry-run)  DRY_RUN="true" ;;
        --auto)     AUTO_MODE="true" ;;
        --channel)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && CHANNEL="${ARGS[$((i+1))]}"
            ;;
        --since)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && SINCE="${ARGS[$((i+1))]}"
            ;;
        --before)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && BEFORE="${ARGS[$((i+1))]}"
            ;;
        --counter)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && COUNTER="${ARGS[$((i+1))]}"
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

if ! command -v claude &>/dev/null; then
    error "Required: claude"
    exit 1
fi

info "Channel: $CHANNEL"

# Build claude flags
CLAUDE_FLAGS="--output-format text"
[[ "$AUTO_MODE" == "true" ]] && CLAUDE_FLAGS="$CLAUDE_FLAGS --dangerously-skip-permissions"

# ------------------------------------------------------------------------------
# Phase 1: claude /slack-read → extract tasks
# ------------------------------------------------------------------------------

info "Phase 1: claude /slack-read..."

# Build slack-read prompt with optional time window
TIME_HINT=""
[[ -n "$SINCE" ]] && TIME_HINT=" since ${SINCE}"
[[ -n "$BEFORE" ]] && TIME_HINT="${TIME_HINT} before ${BEFORE}"
[[ -n "$COUNTER" ]] && TIME_HINT="${TIME_HINT} --counter ${COUNTER}"

if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would run: claude -p '/slack-read ${CHANNEL}${TIME_HINT}'"
    info "[DRY RUN] Would run: claude -p '/slack-report <task summary>'"
    exit 0
fi

SLACK_OUTPUT=$(claude -p "/slack-read ${CHANNEL}${TIME_HINT}. READ ONLY — extract tasks, do NOT investigate, fix, or take any action." --model opus --effort medium $CLAUDE_FLAGS 2>&1 | tee -a "$LOG_FILE")

if [[ -z "$SLACK_OUTPUT" ]] || echo "$SLACK_OUTPUT" | grep -qi "no.*tasks\|no.*messages\|no.*actionable"; then
    warn "No actionable tasks found in $CHANNEL"
    exit 0
fi

success "Tasks extracted from Slack"

# Show tasks
echo ""
echo -e "${GREEN}Tasks found:${NC}"
echo "$SLACK_OUTPUT" | nl -ba
echo ""

# Save tasks to file for looper --brainstorm-prd to pick up
TASKS_FILE="${LOG_DIR}/read-issue-tasks-$(date +%Y%m%d-%H%M%S).md"
echo "$SLACK_OUTPUT" > "$TASKS_FILE"
info "Tasks saved: $TASKS_FILE"

# ------------------------------------------------------------------------------
# Phase 2: claude /slack-report → post summary to Slack
# ------------------------------------------------------------------------------

info "Phase 2: claude /slack-report..."

claude -p "/slack-report Tasks detected from ${CHANNEL}: ${SLACK_OUTPUT}" --model sonnet --effort low $CLAUDE_FLAGS 2>&1 | tee -a "$LOG_FILE" || true

success "Summary reported to Slack"
info "Log: $LOG_FILE"
