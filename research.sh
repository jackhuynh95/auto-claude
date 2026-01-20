#!/bin/bash
# ==============================================================================
# Script: research.sh
# Description: Research a topic and create a GitHub issue with detailed analysis
#
# Usage:       ./research.sh "<topic>" ["<description>"] [--auto]
# Example:     ./research.sh "Add dark mode support"
#              ./research.sh "Add dark mode" "Support dark mode toggle in settings with system preference detection"
#              ./research.sh "Fix login bug" "" --auto
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS_DIR="${SCRIPT_DIR}/prompts"
LOG_FILE="${PROJECT_ROOT}/logs/research-$(date +%Y%m%d-%H%M%S).log"
TOPIC="${1:-}"
DESCRIPTION="${2:-}"
AUTO_MODE=""

# Parse remaining args for --auto flag
shift 2 2>/dev/null || true
for arg in "$@"; do
    [[ "$arg" == "--auto" ]] && AUTO_MODE="--auto"
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo -e "[$1] $2" | tee -a "$LOG_FILE"; }
info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "OK" "${GREEN}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; exit 1; }

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------

preflight() {
    [[ -z "$TOPIC" ]] && error "Usage: $0 \"<topic>\" [--auto]"
    command -v gh &>/dev/null || error "GitHub CLI (gh) not found"
    gh auth status &>/dev/null || error "GitHub CLI not authenticated"
    command -v claude &>/dev/null || error "Claude CLI not found"
    success "Pre-flight passed"
}

# ------------------------------------------------------------------------------
# Determine issue type from topic
# ------------------------------------------------------------------------------

detect_type() {
    local topic_lower=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]')
    if echo "$topic_lower" | grep -qE "fix|bug|error|broken|crash"; then
        echo "bug"
    elif echo "$topic_lower" | grep -qE "add|new|create|implement"; then
        echo "feature"
    else
        echo "enhancement"
    fi
}

# ------------------------------------------------------------------------------
# Generate slug from topic
# ------------------------------------------------------------------------------

generate_slug() {
    echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-50
}

# ------------------------------------------------------------------------------
# Research (via Claude)
# ------------------------------------------------------------------------------

load_prompt() {
    local prompt_file="${PROMPTS_DIR}/${1}.txt"
    if [[ -f "$prompt_file" ]]; then
        cat "$prompt_file"
    else
        error "Prompt file not found: $prompt_file"
    fi
}

run_research() {
    info "Researching: $TOPIC"
    [[ -n "$DESCRIPTION" ]] && info "Description: $DESCRIPTION"

    local flags=""
    if [[ "$AUTO_MODE" == "--auto" ]]; then
        flags="--dangerously-skip-permissions"
        warn "YOLO mode enabled"
    fi

    local slug=$(generate_slug)
    local today=$(date +%Y-%m-%d)

    # Research output file path
    mkdir -p "${PROJECT_ROOT}/research"
    RESEARCH_FILE="${PROJECT_ROOT}/research/${slug}-${today}.md"

    # Load prompt template and substitute placeholders
    local prompt=$(load_prompt "research" | sed "s/{{TOPIC}}/$TOPIC/g" | sed "s/{{DESCRIPTION}}/$DESCRIPTION/g" | sed "s/{{SLUG}}/$slug/g" | sed "s/{{DATE}}/$today/g")

    # Create temp file for Claude output
    local output_file="${PROJECT_ROOT}/logs/research-output-$(date +%Y%m%d-%H%M%S).txt"

    # Run Claude for research with structured approach
    claude -p "$prompt" $flags --output-format text 2>&1 | tee "$output_file" | tee -a "$LOG_FILE"

    # Save full Claude output as research file (raw output)
    cp "$output_file" "$RESEARCH_FILE"
    info "Saved research to: $RESEARCH_FILE"

    # Extract issue body from output
    if grep -q "===ISSUE_BODY_START===" "$output_file"; then
        ISSUE_BODY=$(sed -n '/===ISSUE_BODY_START===/,/===ISSUE_BODY_END===/p' "$output_file" | grep -v "===ISSUE_BODY")
        info "Extracted structured issue body from Claude output"
    else
        warn "No structured issue body found, using fallback template"
        ISSUE_BODY=""
    fi

    # Clean up temp file
    rm -f "$output_file"
}

# ------------------------------------------------------------------------------
# Create GitHub Issue
# ------------------------------------------------------------------------------

create_issue() {
    local type=$(detect_type)
    local title="${type}: ${TOPIC}"

    # Truncate title if too long
    title=$(echo "$title" | cut -c1-72)

    info "Creating GitHub issue..."

    # Use extracted body if available, otherwise fallback
    local body=""
    if [[ -n "${ISSUE_BODY:-}" ]]; then
        body="$ISSUE_BODY"
    else
        local slug=$(generate_slug)
        local today=$(date +%Y-%m-%d)
        body="## Overview

$TOPIC

> 📊 **Research file:** \`research/${slug}-${today}.md\`
> 📅 **Research date:** ${today}

---

## Requirements

- [ ] Review research file for full context
- [ ] Implement the requested change
- [ ] Add tests if applicable
- [ ] Update documentation if needed

---

## Definition of Done

- [ ] Feature works as described
- [ ] No regressions introduced

---

*Generated via research.sh (fallback template)*
*Use \`/plan #<issue-number>\` to create detailed implementation plan*"
    fi

    local issue_url=$(gh issue create \
        --title "$title" \
        --label "$type" \
        --body "$body")

    echo "$issue_url"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "🔬 Research: $TOPIC"
    info "=========================================="

    cd "$PROJECT_ROOT"
    preflight

    # Run research (populates ISSUE_BODY if Claude outputs structured content)
    run_research

    local issue_url=$(create_issue)
    local issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')

    echo ""
    success "=========================================="
    success "🔬 RESEARCH COMPLETE"
    success "=========================================="
    echo "Topic:  $TOPIC"
    echo "Issue:  #$issue_num"
    echo "URL:    $issue_url"
    echo ""
    echo "Next:   ./ship-issue.sh $issue_num"
    success "=========================================="
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
