#!/bin/bash
# ==============================================================================
# Script: brainstorm-issue.sh
# Description: Reads a task description (from arg, file, or stdin), runs Claude
#              /brainstorm to ideate, then creates a pipeline-ready GitHub issue.
#              Bridges the gap between "idea" and "ready_for_dev".
#
# Usage:       ./brainstorm-issue.sh "Add wishlist plugin"
#              ./brainstorm-issue.sh --file task.md
#              echo "Add dark mode" | ./brainstorm-issue.sh --stdin
#              ./brainstorm-issue.sh "Add wishlist" --type feature
#              ./brainstorm-issue.sh "Add wishlist" --dry-run
#              ./brainstorm-issue.sh "Add wishlist" --auto
#              ./brainstorm-issue.sh "Add wishlist" --skip-brainstorm
#
# Designed to be the entry point for the agent swarm workflow:
#   Slack read → brainstorm-issue.sh → looper.sh → fix/ship → report-issue.sh
#
# Requirements:
#   - Claude CLI installed and authenticated
#   - GitHub CLI (gh) installed and authenticated
#   - jq for JSON processing
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
SKIP_BRAINSTORM=""      # skip brainstorm, go straight to issue creation
MODEL_FLAG="--model opus"  # brainstorm = reasoning task → opus

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
        --model)
            if [[ -n "${ARGS[$((i+1))]:-}" ]]; then
                MODEL_FLAG="--model ${ARGS[$((i+1))]}"
            fi
            ;;
        --*) ;; # skip unknown flags
        *)
            # Skip values that follow --file, --type, --model
            if [[ "$i" -gt 0 ]]; then
                prev="${ARGS[$((i-1))]}"
                if [[ "$prev" == "--file" || "$prev" == "--type" || "$prev" == "--model" ]]; then
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

for cmd in claude gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required: $cmd"
        exit 1
    fi
done

info "Task: ${TASK_INPUT:0:80}..."
info "Type: ${ISSUE_TYPE:-auto-detect}"

# ------------------------------------------------------------------------------
# Phase 1: Brainstorm (optional — skip with --skip-brainstorm)
# ------------------------------------------------------------------------------

BRAINSTORM_OUTPUT=""
BRAINSTORM_FILE="${LOG_DIR}/brainstorm-$(date +%Y%m%d-%H%M%S)-output.md"

if [[ "$SKIP_BRAINSTORM" != "true" ]]; then
    info "Phase 1: Brainstorming..."

    BRAINSTORM_PROMPT="You are brainstorming a task for a GitHub issue. Analyze this task and produce:
1. A clear, concise issue title with appropriate prefix ([BUG], [FEATURE], [ENHANCEMENT], [CHORE], [DOCS])
2. A structured issue body with: description, acceptance criteria, technical notes
3. Suggested labels (from: pipeline, ready_for_dev, frontend, hard)

Task: ${TASK_INPUT}

$(if [[ -n "$ISSUE_TYPE" ]]; then echo "Issue type hint: ${ISSUE_TYPE}"; fi)

Output format:
---TITLE---
[PREFIX] Title here
---BODY---
## Description
...
## Acceptance Criteria
- [ ] ...
## Technical Notes
...
---LABELS---
pipeline,ready_for_dev
---END---"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would run: claude $MODEL_FLAG -p '<brainstorm prompt>'"
        echo "$BRAINSTORM_PROMPT" > "$BRAINSTORM_FILE"
        info "Prompt saved to: $BRAINSTORM_FILE"
        exit 0
    fi

    # Run Claude brainstorm
    BRAINSTORM_OUTPUT=$(claude $MODEL_FLAG -p "$BRAINSTORM_PROMPT" 2>/dev/null || echo "")

    if [[ -z "$BRAINSTORM_OUTPUT" ]]; then
        error "Brainstorm failed — no output from Claude"
        exit 1
    fi

    echo "$BRAINSTORM_OUTPUT" > "$BRAINSTORM_FILE"
    info "Brainstorm saved to: $BRAINSTORM_FILE"
else
    info "Skipping brainstorm (--skip-brainstorm)"

    # Auto-generate title from task input
    PREFIX="[FEATURE]"
    case "${ISSUE_TYPE:-feature}" in
        bug)         PREFIX="[BUG]" ;;
        feature)     PREFIX="[FEATURE]" ;;
        enhancement) PREFIX="[ENHANCEMENT]" ;;
        chore)       PREFIX="[CHORE]" ;;
        docs)        PREFIX="[DOCS]" ;;
    esac

    BRAINSTORM_OUTPUT="---TITLE---
${PREFIX} ${TASK_INPUT}
---BODY---
## Description
${TASK_INPUT}

## Acceptance Criteria
- [ ] Implementation complete
- [ ] Tests pass

## Technical Notes
Auto-generated from brainstorm-issue.sh --skip-brainstorm
---LABELS---
pipeline,ready_for_dev
---END---"
fi

# ------------------------------------------------------------------------------
# Phase 2: Parse brainstorm output
# ------------------------------------------------------------------------------

info "Phase 2: Parsing brainstorm output..."

# Extract sections using sed
PARSED_TITLE=$(echo "$BRAINSTORM_OUTPUT" | sed -n '/---TITLE---/,/---BODY---/p' | grep -v '^---' | head -1 | xargs)
PARSED_BODY=$(echo "$BRAINSTORM_OUTPUT" | sed -n '/---BODY---/,/---LABELS---/p' | grep -v '^---')
PARSED_LABELS=$(echo "$BRAINSTORM_OUTPUT" | sed -n '/---LABELS---/,/---END---/p' | grep -v '^---' | head -1 | xargs)

# Fallback if parsing fails
if [[ -z "$PARSED_TITLE" ]]; then
    PREFIX="[FEATURE]"
    case "${ISSUE_TYPE:-feature}" in
        bug) PREFIX="[BUG]" ;;
        feature) PREFIX="[FEATURE]" ;;
        enhancement) PREFIX="[ENHANCEMENT]" ;;
        chore) PREFIX="[CHORE]" ;;
        docs) PREFIX="[DOCS]" ;;
    esac
    PARSED_TITLE="${PREFIX} ${TASK_INPUT:0:70}"
    warn "Title parsing failed, using fallback: $PARSED_TITLE"
fi

if [[ -z "$PARSED_BODY" ]]; then
    PARSED_BODY="## Description\n${TASK_INPUT}"
    warn "Body parsing failed, using task input as body"
fi

if [[ -z "$PARSED_LABELS" ]]; then
    PARSED_LABELS="pipeline,ready_for_dev"
fi

info "Title: $PARSED_TITLE"
info "Labels: $PARSED_LABELS"

# ------------------------------------------------------------------------------
# Phase 3: Create GitHub issue
# ------------------------------------------------------------------------------

info "Phase 3: Creating GitHub issue..."

# Build label args
LABEL_ARGS=""
IFS=',' read -ra LABEL_ARRAY <<< "$PARSED_LABELS"
for label in "${LABEL_ARRAY[@]}"; do
    label=$(echo "$label" | xargs) # trim whitespace
    LABEL_ARGS="$LABEL_ARGS --label \"$label\""
done

if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would create issue:"
    echo "  Title: $PARSED_TITLE"
    echo "  Labels: $PARSED_LABELS"
    echo "  Body:"
    echo "$PARSED_BODY"
    exit 0
fi

# Confirm if not in auto mode
if [[ "$AUTO_MODE" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}About to create issue:${NC}"
    echo -e "  Title: ${GREEN}$PARSED_TITLE${NC}"
    echo -e "  Labels: $PARSED_LABELS"
    echo ""
    read -p "Create this issue? [Y/n] " confirm
    if [[ "${confirm:-Y}" =~ ^[Nn] ]]; then
        warn "Aborted by user"
        exit 0
    fi
fi

# Create the issue
ISSUE_URL=$(gh issue create \
    --title "$PARSED_TITLE" \
    --body "$PARSED_BODY" \
    $(eval echo "$LABEL_ARGS") \
    2>/dev/null)

if [[ -n "$ISSUE_URL" ]]; then
    CREATED_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
    success "Issue created: #${CREATED_NUM} — ${ISSUE_URL}"

    # Post to report-issue.sh if available
    if [[ -f "${SCRIPT_DIR}/report-issue.sh" ]]; then
        info "Sending creation report..."
        bash "${SCRIPT_DIR}/report-issue.sh" "$CREATED_NUM" --clipboard 2>/dev/null || true
    fi
else
    error "Failed to create issue"
    exit 1
fi

info "Log: $LOG_FILE"
