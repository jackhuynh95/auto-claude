#!/bin/bash
# ==============================================================================
# Script: read-issue.sh
# Description: Reads Slack messages via claude /slack-read skill, then pipes
#              each task into brainstorm-issue.sh to create GitHub issues.
#              Same inline pattern as brainstorm-issue.sh uses /brainstorm → /issue.
#
# Usage:       ./read-issue.sh
#              ./read-issue.sh --channel "#general"
#              ./read-issue.sh --dry-run
#              ./read-issue.sh --auto
#              ./read-issue.sh --since "09:00" --before "10:02"
#              ./read-issue.sh --skip-brainstorm   # /slack-read → /issue (no brainstorm)
#
# Flow:  claude /slack-read → tasks → brainstorm-issue.sh --stdin [--auto]
#
# Requirements:
#   - Claude CLI installed and authenticated
#   - GitHub CLI (gh) installed and authenticated
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
SKIP_BRAINSTORM=""

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
        --dry-run)          DRY_RUN="true" ;;
        --auto)             AUTO_MODE="true" ;;
        --skip-brainstorm)  SKIP_BRAINSTORM="true" ;;
        --channel)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && CHANNEL="${ARGS[$((i+1))]}"
            ;;
        --since)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && SINCE="${ARGS[$((i+1))]}"
            ;;
        --before)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && BEFORE="${ARGS[$((i+1))]}"
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

for cmd in claude gh; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required: $cmd"
        exit 1
    fi
done

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

if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would run: claude -p '/slack-read ${CHANNEL}${TIME_HINT}'"
    exit 0
fi

SLACK_OUTPUT=$(claude -p "/slack-read ${CHANNEL}${TIME_HINT}" $CLAUDE_FLAGS 2>&1 | tee -a "$LOG_FILE")

if [[ -z "$SLACK_OUTPUT" ]] || echo "$SLACK_OUTPUT" | grep -qi "no.*tasks\|no.*messages\|no.*actionable"; then
    warn "No actionable tasks found in $CHANNEL"
    exit 0
fi

success "Tasks extracted from Slack"

# Filter to [TYPE] task lines only
TASKS=""
while IFS= read -r line; do
    [[ "$line" =~ ^\[ ]] && TASKS="${TASKS}${line}\n"
done <<< "$SLACK_OUTPUT"
TASKS=$(echo -e "$TASKS" | sed '/^$/d')

if [[ -z "$TASKS" ]]; then
    warn "No [TYPE] task lines found in output"
    exit 0
fi

# Show filtered tasks
TASK_COUNT=$(echo "$TASKS" | wc -l | xargs)
echo ""
echo -e "${GREEN}${TASK_COUNT} task(s) detected:${NC}"
echo "$TASKS" | nl -ba
echo ""

# Confirm before brainstorming (skipped in --auto mode)
if [[ "$AUTO_MODE" != "true" ]]; then
    read -p "Brainstorm and create issues from these tasks? [Y/n] " confirm
    if [[ "${confirm:-Y}" =~ ^[Nn] ]]; then
        warn "Aborted by user"
        info "Tasks saved in log: $LOG_FILE"
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# Phase 2: brainstorm-issue.sh per task
# ------------------------------------------------------------------------------

info "Phase 2: Creating issues from ${TASK_COUNT} task(s)..."

BRAINSTORM_SCRIPT="${SCRIPT_DIR}/brainstorm-issue.sh"
if [[ ! -x "$BRAINSTORM_SCRIPT" ]]; then
    error "brainstorm-issue.sh not found or not executable at: $BRAINSTORM_SCRIPT"
    exit 1
fi

# brainstorm-issue.sh always runs with --auto (sub-script, must not block)
BRAINSTORM_FLAGS="--auto"
[[ "$SKIP_BRAINSTORM" == "true" ]] && BRAINSTORM_FLAGS="$BRAINSTORM_FLAGS --skip-brainstorm"

ISSUE_COUNT=0
while IFS= read -r task; do
    [[ -z "$task" ]] && continue
    info "Processing: ${task:0:80}..."
    echo "$task" | "$BRAINSTORM_SCRIPT" --stdin $BRAINSTORM_FLAGS 2>&1 | tee -a "$LOG_FILE"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
done <<< "$TASKS"

success "Created $ISSUE_COUNT issue(s)"
info "Log: $LOG_FILE"
