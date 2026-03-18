#!/bin/bash
# ==============================================================================
# Script: read-slack.sh
# Description: Read tasks from a Slack channel. Three strategies:
#              1. Slack Bot API (if SLACK_BOT_TOKEN set)
#              2. Open native Slack app → screenshot → OCR via Claude vision
#              3. Manual paste fallback
#
# Usage:       ./read-slack.sh
#              ./read-slack.sh --channel "#medusa-agent-swarm"
#              ./read-slack.sh --method api          # force Slack API
#              ./read-slack.sh --method screenshot    # force screenshot+OCR
#              ./read-slack.sh --method paste         # manual paste
#              ./read-slack.sh --since "2 hours ago"  # API: messages since
#              ./read-slack.sh --limit 10             # API: max messages
#              ./read-slack.sh --pipe                 # pipe output to stdout (for brainstorm-issue.sh --stdin)
#              ./read-slack.sh --dry-run
#
# Output:      Extracted messages printed to stdout (one task per line).
#              Use with: ./read-slack.sh --pipe | ./brainstorm-issue.sh --stdin --auto
#
# Environment:
#   SLACK_BOT_TOKEN  — Bot User OAuth Token (xoxb-...) for API method
#   SLACK_CHANNEL_ID — Channel ID (C...) for API method
#
# Requirements:
#   - For API method: curl, jq, SLACK_BOT_TOKEN, SLACK_CHANNEL_ID
#   - For screenshot method: screencapture (macOS), claude CLI (vision)
#   - For paste method: just a terminal
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/read-slack-$(date +%Y%m%d-%H%M%S).log"
SCREENSHOT_DIR="${LOG_DIR}/screenshots"

# Defaults
METHOD=""              # auto-detect if empty
CHANNEL="#medusa-agent-swarm"
SINCE="24 hours ago"
LIMIT=20
PIPE_MODE=""
DRY_RUN=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$LOG_DIR" "$SCREENSHOT_DIR"

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
        --dry-run) DRY_RUN="true" ;;
        --pipe) PIPE_MODE="true" ;;
        --method)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && METHOD="${ARGS[$((i+1))]}"
            ;;
        --channel)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && CHANNEL="${ARGS[$((i+1))]}"
            ;;
        --since)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && SINCE="${ARGS[$((i+1))]}"
            ;;
        --limit)
            [[ -n "${ARGS[$((i+1))]:-}" ]] && LIMIT="${ARGS[$((i+1))]}"
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Auto-detect method
# ------------------------------------------------------------------------------

detect_method() {
    if [[ -n "$METHOD" ]]; then
        echo "$METHOD"
        return
    fi

    # Priority 1: Slack API if token available
    if [[ -n "${SLACK_BOT_TOKEN:-}" ]] && [[ -n "${SLACK_CHANNEL_ID:-}" ]]; then
        echo "api"
        return
    fi

    # Priority 2: Screenshot+OCR if on macOS with claude
    if [[ "$(uname)" == "Darwin" ]] && command -v screencapture &>/dev/null && command -v claude &>/dev/null; then
        echo "screenshot"
        return
    fi

    # Priority 3: Manual paste
    echo "paste"
}

# ------------------------------------------------------------------------------
# Method 1: Slack Bot API
# ------------------------------------------------------------------------------

read_via_api() {
    info "Reading via Slack API..."

    if [[ -z "${SLACK_BOT_TOKEN:-}" ]]; then
        error "SLACK_BOT_TOKEN not set"
        exit 1
    fi
    if [[ -z "${SLACK_CHANNEL_ID:-}" ]]; then
        error "SLACK_CHANNEL_ID not set"
        exit 1
    fi

    # Calculate oldest timestamp
    local oldest=$(date -v-"${SINCE// /}" +%s 2>/dev/null || date -d "$SINCE" +%s 2>/dev/null || echo "0")

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would call: conversations.history channel=$SLACK_CHANNEL_ID oldest=$oldest limit=$LIMIT"
        return
    fi

    # Fetch messages
    local response=$(curl -s \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
        -H "Content-Type: application/json" \
        "https://slack.com/api/conversations.history?channel=${SLACK_CHANNEL_ID}&oldest=${oldest}&limit=${LIMIT}" 2>/dev/null)

    local ok=$(echo "$response" | jq -r '.ok')
    if [[ "$ok" != "true" ]]; then
        local err=$(echo "$response" | jq -r '.error // "unknown"')
        error "Slack API error: $err"
        exit 1
    fi

    # Extract message texts, skip bot messages and join messages
    local messages=$(echo "$response" | jq -r '
        .messages[]
        | select(.subtype == null or .subtype == "")
        | select(.bot_id == null)
        | .text
    ' 2>/dev/null)

    if [[ -z "$messages" ]]; then
        warn "No messages found in last $SINCE"
        return
    fi

    local count=$(echo "$messages" | wc -l | xargs)
    success "Found $count message(s)"

    echo "$messages"
}

# ------------------------------------------------------------------------------
# Method 2: Screenshot + OCR (macOS native)
# ------------------------------------------------------------------------------

read_via_screenshot() {
    info "Reading via screenshot + OCR..."
    info "Opening Slack and taking screenshot..."

    # Open Slack native app
    open -a Slack 2>/dev/null || true
    sleep 2

    local screenshot_file="${SCREENSHOT_DIR}/slack-$(date +%Y%m%d-%H%M%S).png"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would: open Slack → screencapture → claude vision OCR"
        return
    fi

    # Interactive screenshot — user selects the area with messages
    info "Select the Slack message area to capture (drag to select)..."
    screencapture -i "$screenshot_file"

    if [[ ! -f "$screenshot_file" ]]; then
        error "Screenshot cancelled or failed"
        exit 1
    fi

    info "Screenshot saved: $screenshot_file"
    info "Running OCR via Claude vision..."

    # Use Claude vision to extract text from screenshot
    local ocr_output=$(claude -p "Extract all task/message text from this Slack screenshot. Output each distinct task or message on its own line, stripped of usernames and timestamps. Only include actionable items (tasks, bugs, feature requests). Skip greetings, reactions, and status messages.

If no actionable tasks found, output: NO_TASKS_FOUND" --model sonnet --image "$screenshot_file" 2>/dev/null)

    if [[ -z "$ocr_output" ]] || [[ "$ocr_output" == "NO_TASKS_FOUND" ]]; then
        warn "No actionable tasks found in screenshot"
        return
    fi

    success "Extracted tasks from screenshot"
    echo "$ocr_output"
}

# ------------------------------------------------------------------------------
# Method 3: Manual paste
# ------------------------------------------------------------------------------

read_via_paste() {
    info "Manual paste mode — paste Slack messages below, then press Ctrl+D when done:"
    echo "" >&2

    local pasted=""
    pasted=$(cat)

    if [[ -z "$pasted" ]]; then
        warn "No input received"
        return
    fi

    # Optionally clean up with Claude
    if command -v claude &>/dev/null; then
        info "Cleaning up pasted text..."
        local cleaned=$(claude -p "Extract actionable tasks from this Slack conversation. Output each task on its own line. Skip greetings, reactions, timestamps, usernames. Only include bugs, features, enhancements, or chores.

Input:
$pasted

If no actionable tasks, output: NO_TASKS_FOUND" --model haiku 2>/dev/null)

        if [[ -n "$cleaned" ]] && [[ "$cleaned" != "NO_TASKS_FOUND" ]]; then
            echo "$cleaned"
            return
        fi
    fi

    # Raw fallback
    echo "$pasted"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

DETECTED_METHOD=$(detect_method)
info "Channel: $CHANNEL"
info "Method: $DETECTED_METHOD"

OUTPUT=""

case "$DETECTED_METHOD" in
    api)        OUTPUT=$(read_via_api) ;;
    screenshot) OUTPUT=$(read_via_screenshot) ;;
    paste)      OUTPUT=$(read_via_paste) ;;
    *)
        error "Unknown method: $DETECTED_METHOD. Use: api, screenshot, paste"
        exit 1
        ;;
esac

if [[ -z "$OUTPUT" ]]; then
    warn "No tasks extracted"
    exit 0
fi

# Save to log
echo "$OUTPUT" >> "$LOG_FILE"

# Output
if [[ "$PIPE_MODE" == "true" ]]; then
    # Pipe mode: raw output to stdout for chaining
    echo "$OUTPUT"
else
    # Interactive: show tasks with numbers
    echo ""
    echo -e "${GREEN}Tasks found:${NC}"
    echo "$OUTPUT" | nl -ba
    echo ""
    info "To pipe into brainstorm-issue.sh:"
    info "  ./read-slack.sh --pipe | ./brainstorm-issue.sh --stdin --auto"
fi

info "Log: $LOG_FILE"
