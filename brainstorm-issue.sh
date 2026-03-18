#!/bin/bash
# ==============================================================================
# Script: brainstorm-issue.sh
# Description: Runs claude /brainstorm inline, then claude /issue to create a
#              pipeline-ready GitHub issue. Same pattern as ship-issue uses
#              /code:auto and report-issue uses /slack-report.
#
# Usage:       ./brainstorm-issue.sh "Add wishlist plugin"
#              ./brainstorm-issue.sh --file task.md
#              echo "Add dark mode" | ./brainstorm-issue.sh --stdin
#              ./brainstorm-issue.sh "Add wishlist" --type feature
#              ./brainstorm-issue.sh "Add wishlist" --dry-run
#              ./brainstorm-issue.sh "Add wishlist" --auto
#              ./brainstorm-issue.sh "Add wishlist" --skip-brainstorm
#
# Flow:  claude /brainstorm → brainstorm output → claude /issue → GitHub issue
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
ISSUE_TYPE=""           # bug, feature, enhancement, chore, docs
TASK_INPUT=""
INPUT_FILE=""
FROM_STDIN=""
SKIP_BRAINSTORM=""      # skip brainstorm, go straight to /issue

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
        --dry-run)          DRY_RUN="true" ;;
        --auto)             AUTO_MODE="true" ;;
        --stdin)            FROM_STDIN="true" ;;
        --skip-brainstorm)  SKIP_BRAINSTORM="true" ;;
        --file)
            if [[ -n "${ARGS[$((i+1))]:-}" ]]; then
                INPUT_FILE="${ARGS[$((i+1))]}"
            fi
            ;;
        --type)
            if [[ -n "${ARGS[$((i+1))]:-}" ]]; then
                ISSUE_TYPE="${ARGS[$((i+1))]}"
            fi
            ;;
        --*) ;; # skip unknown flags
        *)
            # Skip values that follow --file, --type
            if [[ "$i" -gt 0 ]]; then
                prev="${ARGS[$((i-1))]}"
                if [[ "$prev" == "--file" || "$prev" == "--type" ]]; then
                    continue
                fi
            fi
            POSITIONAL+=("${ARGS[$i]}")
            ;;
    esac
done

# Resolve task input from sources
if [[ "$FROM_STDIN" == "true" ]]; then
    TASK_INPUT=$(cat)
elif [[ -n "$INPUT_FILE" ]]; then
    if [[ ! -f "$INPUT_FILE" ]]; then
        error "File not found: $INPUT_FILE"
        exit 1
    fi
    TASK_INPUT=$(cat "$INPUT_FILE")
elif [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    TASK_INPUT="${POSITIONAL[*]}"
fi

if [[ -z "$TASK_INPUT" ]]; then
    error "Usage: $0 <task-description> [--type bug|feature|enhancement|chore|docs] [--dry-run] [--auto]"
    error "       $0 --file task.md [flags...]"
    error "       echo 'task' | $0 --stdin [flags...]"
    exit 1
fi

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

for cmd in claude gh; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required: $cmd"
        exit 1
    fi
done

info "Task: ${TASK_INPUT:0:80}..."
info "Type: ${ISSUE_TYPE:-auto-detect}"

# Build claude flags
CLAUDE_FLAGS="--output-format text"
[[ "$AUTO_MODE" == "true" ]] && CLAUDE_FLAGS="$CLAUDE_FLAGS --dangerously-skip-permissions"

# ------------------------------------------------------------------------------
# Phase 1: claude /brainstorm (optional — skip with --skip-brainstorm)
# ------------------------------------------------------------------------------

BRAINSTORM_OUTPUT=""

if [[ "$SKIP_BRAINSTORM" != "true" ]]; then
    info "Phase 1: claude /brainstorm..."

    TYPE_HINT=""
    [[ -n "$ISSUE_TYPE" ]] && TYPE_HINT=" (type hint: ${ISSUE_TYPE})"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would run: claude -p '/brainstorm ${TASK_INPUT:0:60}...${TYPE_HINT}'"
        exit 0
    fi

    BRAINSTORM_OUTPUT=$(claude -p "/brainstorm ${TASK_INPUT}${TYPE_HINT}" --model opus --effort max $CLAUDE_FLAGS 2>&1 | tee -a "$LOG_FILE")

    if [[ -z "$BRAINSTORM_OUTPUT" ]]; then
        error "Brainstorm failed — no output from Claude"
        exit 1
    fi

    success "Brainstorm complete"
else
    info "Skipping brainstorm (--skip-brainstorm)"
    BRAINSTORM_OUTPUT="$TASK_INPUT"
fi

# ------------------------------------------------------------------------------
# Phase 2: claude /issue (creates GitHub issue from brainstorm output)
# ------------------------------------------------------------------------------

info "Phase 2: claude /issue..."

# Build /issue prompt — explicit instruction to create, not ask
ISSUE_PROMPT="/issue Create a GitHub issue from this brainstorm. Do NOT ask questions — create the issue immediately with title, body, and labels (pipeline, ready_for_dev, plus type label). Brainstorm output:
${BRAINSTORM_OUTPUT}"

if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would run: claude -p '/issue <brainstorm output>'"
    echo "$BRAINSTORM_OUTPUT"
    exit 0
fi

# Confirm if not in auto mode
if [[ "$AUTO_MODE" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}Brainstorm output:${NC}"
    echo "$BRAINSTORM_OUTPUT" | head -20
    echo ""
    read -p "Create issue from this brainstorm? [Y/n] " confirm
    if [[ "${confirm:-Y}" =~ ^[Nn] ]]; then
        warn "Aborted by user"
        info "Brainstorm saved in log: $LOG_FILE"
        exit 0
    fi
fi

# Run /issue via Claude — low effort, brainstorm already did the thinking
ISSUE_OUTPUT=$(claude -p "$ISSUE_PROMPT" --model sonnet --effort medium $CLAUDE_FLAGS 2>&1 | tee -a "$LOG_FILE")

if [[ -n "$ISSUE_OUTPUT" ]]; then
    success "Issue creation complete"
    echo "$ISSUE_OUTPUT"
else
    error "Failed to create issue"
    exit 1
fi

info "Log: $LOG_FILE"
