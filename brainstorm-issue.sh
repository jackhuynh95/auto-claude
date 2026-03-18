#!/bin/bash
# ==============================================================================
# Script: brainstorm-issue.sh
# Description: Single claude session that activates /brainstorm then /issue
#              to create pipeline-ready GitHub issues.
#
# Usage:       ./brainstorm-issue.sh "Add wishlist plugin"
#              ./brainstorm-issue.sh --file tasks.txt
#              echo "Add dark mode" | ./brainstorm-issue.sh --stdin
#              ./brainstorm-issue.sh --file tasks.txt --auto
#              ./brainstorm-issue.sh "task" --type feature --dry-run
#
# Flow:  single claude session: /brainstorm → /issue → GitHub issue URL
#
# Requirements:
#   - Claude CLI installed and authenticated
#   - GitHub CLI (gh) installed and authenticated
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/brainstorm-$(date +%Y%m%d-%H%M%S).log"

# Defaults
DRY_RUN=""
AUTO_MODE=""
ISSUE_TYPE=""
TASK_INPUT=""
INPUT_FILE=""
FROM_STDIN=""

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
# Parse arguments
# ------------------------------------------------------------------------------

ARGS=("$@")
POSITIONAL=()

for i in "${!ARGS[@]}"; do
    case "${ARGS[$i]}" in
        --dry-run)  DRY_RUN="true" ;;
        --auto)     AUTO_MODE="true" ;;
        --stdin)    FROM_STDIN="true" ;;
        --file)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && INPUT_FILE="${ARGS[$((i+1))]}"
            ;;
        --type)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && ISSUE_TYPE="${ARGS[$((i+1))]}"
            ;;
        --*) ;;
        *)
            if [[ "$i" -gt 0 ]]; then
                prev="${ARGS[$((i-1))]}"
                [[ "$prev" == "--file" || "$prev" == "--type" ]] && continue
            fi
            POSITIONAL+=("${ARGS[$i]}")
            ;;
    esac
done

# Resolve task input
if [[ "$FROM_STDIN" == "true" ]]; then
    TASK_INPUT=$(cat)
elif [[ -n "$INPUT_FILE" ]]; then
    [[ ! -f "$INPUT_FILE" ]] && { error "File not found: $INPUT_FILE"; exit 1; }
    TASK_INPUT=$(cat "$INPUT_FILE")
elif [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    TASK_INPUT="${POSITIONAL[*]}"
fi

if [[ -z "$TASK_INPUT" ]]; then
    error "Usage: $0 <task> [--type bug|feature|chore|docs|test] [--dry-run] [--auto]"
    error "       $0 --file tasks.txt | echo 'task' | $0 --stdin"
    exit 1
fi

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

for cmd in claude gh; do
    command -v "$cmd" &>/dev/null || { error "Required: $cmd"; exit 1; }
done

# Count tasks (lines with [TYPE] prefix)
TASK_COUNT=$(echo "$TASK_INPUT" | grep -cE '\[(BUG|FEATURE|ENHANCEMENT|CHORE|DOCS|TEST)\]' 2>/dev/null || true)
[[ "$TASK_COUNT" -eq 0 ]] && TASK_COUNT=1

info "Tasks: ${TASK_COUNT}"
info "Input: ${TASK_INPUT:0:80}..."
[[ -n "$ISSUE_TYPE" ]] && info "Type hint: $ISSUE_TYPE"

# Build claude flags
CLAUDE_FLAGS="--output-format text"
[[ "$AUTO_MODE" == "true" ]] && CLAUDE_FLAGS="$CLAUDE_FLAGS --dangerously-skip-permissions"

# Confirm if not in auto mode
if [[ "$AUTO_MODE" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}Tasks to brainstorm:${NC}"
    echo "$TASK_INPUT"
    echo ""
    read -p "Brainstorm and create ${TASK_COUNT} GitHub issue(s)? [Y/n] " confirm
    if [[ "${confirm:-Y}" =~ ^[Nn] ]]; then
        warn "Aborted by user"
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# Single claude session: /brainstorm → /issue
# ------------------------------------------------------------------------------

TYPE_HINT=""
[[ -n "$ISSUE_TYPE" ]] && TYPE_HINT="Type hint: ${ISSUE_TYPE}. "

PROMPT="You have ${TASK_COUNT} task(s) to process. For EACH task:

Step 1: Activate /brainstorm skill — deep analysis of the task
Step 2: Activate /issue skill — create a GitHub issue with labels (pipeline, ready_for_dev, plus type label)

${TYPE_HINT}Tasks:
${TASK_INPUT}

IMPORTANT: Create ALL ${TASK_COUNT} GitHub issue(s). After creating each issue, output the issue URL in bold: **https://github.com/...issues/N**
At the end, output a summary line: **Created N issue(s)**"

if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would run single claude session with /brainstorm → /issue"
    info "[DRY RUN] Tasks: ${TASK_COUNT}"
    echo "$TASK_INPUT"
    exit 0
fi

info "Running claude session: /brainstorm → /issue for ${TASK_COUNT} task(s)..."

OUTPUT=$(claude -p "$PROMPT" --model opus --effort max $CLAUDE_FLAGS 2>&1 | tee -a "$LOG_FILE")

if [[ -n "$OUTPUT" ]]; then
    success "Brainstorm + issue creation complete"
    echo "$OUTPUT"
else
    error "Failed — no output from Claude"
    exit 1
fi

info "Log: $LOG_FILE"
