#!/bin/bash
# ==============================================================================
# Script: looper.sh
# Description: Scans GitHub issues by pipeline label and dispatches to the right
#              script based on issue type. The "commander" that /loop calls.
#              [BUG] → fix-issue.sh | [FEATURE]/[ENHANCEMENT] → ship-issue.sh
#              [WONTFIX]/[WONTFEAT] → skipped | Bugs processed first (priority)
#
# Smart label routing:
#   "frontend" label  → auto-adds --frontend-design
#   "hard" label       → auto-adds --hard (opus for complex bugs)
#   [DOCS]/[CHORE]     → auto-adds --no-test (skip tests)
#
# Usage:
#   ./looper.sh                          # full scan (all labels)
#   ./looper.sh --label ready_for_dev    # single label
#   ./looper.sh --label "ready_for_dev,ready_for_test"  # multiple labels
#   ./looper.sh --dry-run                # scan only
#   ./looper.sh --limit 3               # cap per run
#   ./looper.sh --profile overnight      # scheduling profile
#   ./looper.sh --issues "154,153"        # explicit issue list, processed in given order
#   ./looper.sh --sort oldest             # sort by oldest first (default: newest)
#   ./looper.sh --read-slack             # read-issue.sh → brainstorm → issue before pipeline
#   ./looper.sh --read-slack --channel "#medusa"  # read specific channel
#   ./looper.sh --read-slack --label ready_for_dev  # Slack + single label
#
# Via /loop (Claude Code built-in, runs prompt on interval):
#   /loop 2h ./looper.sh
#   /loop 2h ./looper.sh --profile overnight
#   /loop 4h ./looper.sh --read-slack --profile morning
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/looper-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="${LOG_DIR}/.looper.lock"

# Defaults
DRY_RUN=""
LIMIT=10
FILTER_LABEL=""
PROFILE=""
READ_SLACK=""           # --read-slack: scan Slack before pipeline run
SLACK_CHANNEL=""        # --channel: Slack channel for read-issue.sh
SLACK_SINCE=""          # --since: time filter for read-issue.sh
SLACK_BEFORE=""         # --before: time filter for read-issue.sh
SLACK_COUNTER=""        # --counter: exact task count for read-issue.sh
BRAINSTORM_PRD=""       # --brainstorm-prd: brainstorm tasks into GitHub issues
ISSUE_LIST=""           # --issues: explicit issue numbers in order (e.g., "154,153")
SORT_ORDER="newest"     # --sort: newest (default) or oldest

# Run results tracking
TOTAL_PROCESSED=0
TOTAL_SUCCEEDED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
RUN_START=$(date +%s)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse flags
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    case "${ARGS[$i]}" in
        --dry-run) DRY_RUN="true" ;;
        --limit)
            LIMIT="${ARGS[$((i+1))]:-10}"
            ;;
        --label)
            FILTER_LABEL="${ARGS[$((i+1))]:-}"
            ;;
        --profile)
            PROFILE="${ARGS[$((i+1))]:-}"
            ;;
        --read-slack) READ_SLACK="true" ;;
        --channel)
            SLACK_CHANNEL="${ARGS[$((i+1))]:-}"
            ;;
        --since)
            SLACK_SINCE="${ARGS[$((i+1))]:-}"
            ;;
        --before)
            SLACK_BEFORE="${ARGS[$((i+1))]:-}"
            ;;
        --counter)
            SLACK_COUNTER="${ARGS[$((i+1))]:-}"
            ;;
        --brainstorm-prd) BRAINSTORM_PRD="true" ;;
        --issues)
            ISSUE_LIST="${ARGS[$((i+1))]:-}"
            ;;
        --sort)
            SORT_ORDER="${ARGS[$((i+1))]:-newest}"
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

mkdir -p "$LOG_DIR"

log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }

# ------------------------------------------------------------------------------
# Lock File — prevent concurrent looper runs
# ------------------------------------------------------------------------------

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            warn "Another looper is running (PID: $lock_pid) — exiting"
            exit 0
        else
            warn "Stale lock file found (PID: $lock_pid dead) — removing"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# Clean up lock on exit (normal or error)
trap release_lock EXIT

# ------------------------------------------------------------------------------
# Profile Loading (Issue 05)
# ------------------------------------------------------------------------------

PROFILE_LABELS=""
PROFILE_FLAGS=""
PROFILE_LIMIT=""
PROFILE_SUMMARY=""

load_profile() {
    local profile_file="${SCRIPT_DIR}/looper-profiles.sh"
    if [[ -f "$profile_file" ]]; then
        source "$profile_file"
    fi

    case "$PROFILE" in
        overnight)
            PROFILE_LABELS="ready_for_dev"
            PROFILE_FLAGS="--auto --hard"
            PROFILE_LIMIT=5
            ;;
        morning)
            PROFILE_LABELS="ready_for_test"
            PROFILE_FLAGS=""  # ready_for_test routes to verify-issue.sh directly
            PROFILE_LIMIT=10
            PROFILE_SUMMARY="true"
            ;;
        daytime)
            PROFILE_LABELS="ready_for_test"
            PROFILE_FLAGS=""  # ready_for_test routes to verify-issue.sh directly
            PROFILE_LIMIT=3
            ;;
        continuous)
            PROFILE_LABELS="ready_for_dev,ready_for_test"
            PROFILE_FLAGS="--auto"
            PROFILE_LIMIT=3
            ;;
        "")
            # No profile, use defaults
            ;;
        *)
            # Check if profile function exists from looper-profiles.sh
            if type "profile_${PROFILE}" &>/dev/null; then
                "profile_${PROFILE}"
                PROFILE_LABELS="${LABELS:-}"
                PROFILE_FLAGS="${FLAGS:-}"
                PROFILE_LIMIT="${LIMIT:-}"
                PROFILE_SUMMARY="${SUMMARY:-}"
            else
                warn "Unknown profile: $PROFILE (using defaults)"
            fi
            ;;
    esac

    # Profile overrides (CLI flags take precedence)
    [[ -z "$FILTER_LABEL" ]] && [[ -n "$PROFILE_LABELS" ]] && FILTER_LABEL="$PROFILE_LABELS"
    [[ -n "$PROFILE_LIMIT" ]] && LIMIT="$PROFILE_LIMIT"
}

# ------------------------------------------------------------------------------
# Pipeline Summary
# ------------------------------------------------------------------------------

print_summary() {
    local ready_dev=$(gh issue list --label "ready_for_dev" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local ready_test=$(gh issue list --label "ready_for_test" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local shipped=$(gh issue list --label "shipped" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local verified=$(gh issue list --label "verified" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local blocked=$(gh issue list --label "blocked" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local design_review=$(gh issue list --label "needs_design_review" --state open --json number --jq 'length' 2>/dev/null || echo "?")
    local frontend=$(gh issue list --label "frontend" --state open --json number --jq 'length' 2>/dev/null || echo "?")

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}  Pipeline Summary — $(date '+%Y-%m-%d %H:%M')${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "  ready_for_dev:       ${ready_dev} issues"
    echo -e "  ready_for_test:      ${ready_test} issues"
    echo -e "  shipped:             ${shipped} issues"
    echo -e "  verified:            ${verified} issues"
    echo -e "  blocked:             ${blocked} issues"
    echo -e "  needs_design_review: ${design_review} issues"
    echo -e "  frontend:            ${frontend} issues"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
}

# Print run results (end of run)
print_run_results() {
    local run_end=$(date +%s)
    local duration=$(( run_end - RUN_START ))
    local mins=$(( duration / 60 ))
    local secs=$(( duration % 60 ))

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}  Run Results${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "  Processed:  ${TOTAL_PROCESSED}"
    echo -e "  Succeeded:  ${GREEN}${TOTAL_SUCCEEDED}${NC}"
    echo -e "  Failed:     ${RED}${TOTAL_FAILED}${NC}"
    echo -e "  Skipped:    ${YELLOW}${TOTAL_SKIPPED}${NC}"
    echo -e "  Duration:   ${mins}m ${secs}s"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# Log Transformer — batch rename *.log → *.md at end of cycle
# .md renders nicely on GitHub, OS previews, and Slack shares
# ------------------------------------------------------------------------------

transform_logs() {
    local count=0
    for f in "$LOG_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        # Skip the current looper log (still being written via tee)
        [[ "$f" == "$LOG_FILE" ]] && continue
        mv "$f" "${f%.log}.md"
        ((count++))
    done
    # Rename current looper log last (tee holds file handle, safe on Unix)
    if [[ -f "$LOG_FILE" ]]; then
        local new_log="${LOG_FILE%.log}.md"
        mv "$LOG_FILE" "$new_log"
        LOG_FILE="$new_log"
        ((count++))
    fi
    [[ $count -gt 0 ]] && info "Transformed $count log file(s) to .md"
}

# ------------------------------------------------------------------------------
# Slack Reader + Report (new scripts integration)
# ------------------------------------------------------------------------------

# Read tasks from Slack and create issues via read-issue.sh
read_slack_tasks() {
    if [[ ! -f "${SCRIPT_DIR}/read-issue.sh" ]]; then
        warn "read-issue.sh not found — skipping Slack read"
        return
    fi

    # Build passthrough flags
    local extra_flags=""
    [[ -n "$SLACK_CHANNEL" ]] && extra_flags="$extra_flags --channel $SLACK_CHANNEL"
    [[ -n "$SLACK_SINCE" ]] && extra_flags="$extra_flags --since \"$SLACK_SINCE\""
    [[ -n "$SLACK_BEFORE" ]] && extra_flags="$extra_flags --before \"$SLACK_BEFORE\""
    [[ -n "$SLACK_COUNTER" ]] && extra_flags="$extra_flags --counter $SLACK_COUNTER"

    info "Reading tasks from Slack via read-issue.sh... ${SLACK_CHANNEL:-#medusa-agent-swarm} ${SLACK_SINCE:+(since $SLACK_SINCE)} ${SLACK_BEFORE:+(before $SLACK_BEFORE)} ${SLACK_COUNTER:+(counter $SLACK_COUNTER)}"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would run: read-issue.sh --auto $extra_flags"
        return
    fi

    if bash "${SCRIPT_DIR}/read-issue.sh" --auto $extra_flags 2>&1 | tee -a "$LOG_FILE"; then
        success "Slack read → issue creation complete"
    else
        warn "read-issue.sh failed or no tasks found"
    fi
}

# Brainstorm tasks into GitHub issues via brainstorm-issue.sh
brainstorm_prd_tasks() {
    if [[ ! -f "${SCRIPT_DIR}/brainstorm-issue.sh" ]]; then
        warn "brainstorm-issue.sh not found — skipping brainstorm"
        return
    fi

    # Find latest tasks file from read-issue.sh
    local tasks_file=$(ls -t "${LOG_DIR}"/read-issue-tasks-*.md 2>/dev/null | head -1)
    if [[ -z "$tasks_file" ]]; then
        warn "No tasks file found — run --read-slack first"
        return
    fi

    info "Brainstorming tasks from: $tasks_file"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would brainstorm each task from: $tasks_file"
        cat "$tasks_file"
        return
    fi

    # Split tasks by --- separator, or treat whole file as one task
    local count=0
    local blocks=()
    local block=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "---" ]]; then
            [[ -n "$(echo "$block" | tr -d '[:space:]')" ]] && blocks+=("$block")
            block=""
        else
            block="${block}${line}
"
        fi
    done < "$tasks_file"
    # Last block
    [[ -n "$(echo "$block" | tr -d '[:space:]')" ]] && blocks+=("$block")

    # If no --- separators found, treat whole file as one task
    if [[ ${#blocks[@]} -eq 0 ]]; then
        blocks=("$(cat "$tasks_file")")
    fi

    for task_block in "${blocks[@]}"; do
        [[ -z "$(echo "$task_block" | tr -d '[:space:]')" ]] && continue
        count=$((count + 1))
        info "Brainstorming task $count of ${#blocks[@]}..."
        echo "$task_block" | bash "${SCRIPT_DIR}/brainstorm-issue.sh" --stdin --auto 2>&1 | tee -a "$LOG_FILE"
    done

    success "Brainstormed $count task(s) into GitHub issues"
}

# Post report to Slack after fix/ship/verify
report_issue() {
    local num="$1"
    if [[ ! -f "${SCRIPT_DIR}/report-issue.sh" ]]; then
        return
    fi
    info "Reporting #$num to Slack..."
    bash "${SCRIPT_DIR}/report-issue.sh" "$num" --auto 2>&1 | tee -a "$LOG_FILE" || true
}

# ------------------------------------------------------------------------------
# Issue Type Detection (from CLAUDE.md conventions)
# ------------------------------------------------------------------------------
# [BUG]         → fix-issue.sh
# [FEATURE]     → ship-issue.sh
# [ENHANCEMENT] → ship-issue.sh
# [CHORE]       → ship-issue.sh  (+ --no-test)
# [DOCS]        → ship-issue.sh  (+ --no-test)
# [WONTFIX]     → SKIP
# [WONTFEAT]    → SKIP

get_issue_type() {
    local title="$1"
    local upper_title=$(echo "$title" | tr '[:lower:]' '[:upper:]')

    if [[ "$upper_title" == *"[WONTFIX]"* ]] || [[ "$upper_title" == *"[WONTFEAT]"* ]]; then
        echo "skip"
    elif [[ "$upper_title" == *"[BUG]"* ]]; then
        echo "bug"
    else
        # FEATURE, ENHANCEMENT, CHORE, DOCS, or no prefix → ship
        echo "ship"
    fi
}

# Check if title prefix suggests skipping tests
is_no_test_type() {
    local title="$1"
    local upper_title=$(echo "$title" | tr '[:lower:]' '[:upper:]')
    [[ "$upper_title" == *"[DOCS]"* ]] || [[ "$upper_title" == *"[CHORE]"* ]]
}

get_script_for_type() {
    local issue_type="$1"
    case "$issue_type" in
        bug)  echo "fix-issue.sh" ;;
        ship) echo "ship-issue.sh" ;;
        *)    echo "" ;;  # skip
    esac
}

# ------------------------------------------------------------------------------
# Smart Flag Builder — detects labels + title prefix to compose flags
# ------------------------------------------------------------------------------

build_issue_flags() {
    local base_flags="$1"
    local title="$2"
    local labels_json="$3"  # raw jq array of label objects

    local issue_flags="$base_flags"

    # Label: "frontend" → --frontend-design (auto UI review)
    local has_frontend=$(echo "$labels_json" | jq -r 'map(.name) | any(. == "frontend")')
    [[ "$has_frontend" == "true" ]] && issue_flags="$issue_flags --frontend-design"

    # Label: "hard" → --hard (opus for complex issues)
    local has_hard=$(echo "$labels_json" | jq -r 'map(.name) | any(. == "hard")')
    [[ "$has_hard" == "true" ]] && issue_flags="$issue_flags --hard"

    # Title prefix: [DOCS] or [CHORE] → --no-test
    if is_no_test_type "$title"; then
        issue_flags="$issue_flags --no-test"
    fi

    echo "$issue_flags"
}

# Build human-readable suffix for log line
build_flag_summary() {
    local title="$1"
    local labels_json="$2"
    local parts=""

    local has_frontend=$(echo "$labels_json" | jq -r 'map(.name) | any(. == "frontend")')
    [[ "$has_frontend" == "true" ]] && parts="${parts}+design "

    local has_hard=$(echo "$labels_json" | jq -r 'map(.name) | any(. == "hard")')
    [[ "$has_hard" == "true" ]] && parts="${parts}+hard "

    is_no_test_type "$title" && parts="${parts}+no-test "

    echo "$parts"
}

# ------------------------------------------------------------------------------
# Issue Processing
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Explicit Issue List Processing (--issues "154,153")
# Processes issues in the exact order specified, regardless of labels
# ------------------------------------------------------------------------------

process_explicit_issues() {
    local flags="$1"

    IFS=',' read -ra NUMS <<< "$ISSUE_LIST"
    info "Processing ${#NUMS[@]} explicit issue(s) through full pipeline: ${ISSUE_LIST}"

    for num in "${NUMS[@]}"; do
        num=$(echo "$num" | tr -d ' ')  # trim whitespace
        [[ -z "$num" ]] && continue

        # Fetch issue details
        local issue=$(gh issue view "$num" --json number,title,labels,state 2>/dev/null || echo "{}")
        local title=$(echo "$issue" | jq -r '.title // "unknown"')
        local state=$(echo "$issue" | jq -r '.state // "unknown"')
        local labels_json=$(echo "$issue" | jq '.labels // []')

        if [[ "$title" == "unknown" ]] || [[ "$state" != "OPEN" ]]; then
            warn "Skipping #$num: not found or not open (state: $state)"
            TOTAL_SKIPPED=$(( TOTAL_SKIPPED + 1 ))
            continue
        fi

        local issue_type=$(get_issue_type "$title")
        local script=$(get_script_for_type "$issue_type")

        if [[ -z "$script" ]]; then
            warn "Skipping #$num: $title (WONTFIX/WONTFEAT)"
            TOTAL_SKIPPED=$(( TOTAL_SKIPPED + 1 ))
            continue
        fi

        local issue_flags=$(build_issue_flags "$flags" "$title" "$labels_json")
        local flag_summary=$(build_flag_summary "$title" "$labels_json")
        local issue_start=$(date +%s)

        info "══════════════════════════════════════"
        info "#$num full pipeline: $title"
        info "══════════════════════════════════════"

        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY RUN] Would run full pipeline for #$num:"
            info "  1. $script $num $issue_flags"
            info "  2. verify-issue.sh $num --auto --model sonnet"
            info "  3. merge PR + close issue"
            TOTAL_PROCESSED=$(( TOTAL_PROCESSED + 1 ))
            continue
        fi

        # ── Stage 1: Fix/Ship (ready_for_dev → ready_for_test) ──
        info "[Stage 1/3] $script #$num ($issue_type ${flag_summary})"
        cd "$PROJECT_ROOT"
        git checkout main 2>/dev/null || true
        git pull --ff-only 2>/dev/null || true

        if ! bash "${SCRIPT_DIR}/${script}" "$num" $issue_flags 2>&1 | tee -a "$LOG_FILE"; then
            local issue_end=$(date +%s)
            warn "#$num fix/ship failed ($(( issue_end - issue_start ))s) — skipping to next issue"
            TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
            TOTAL_PROCESSED=$(( TOTAL_PROCESSED + 1 ))
            cd "$PROJECT_ROOT"
            git checkout main 2>/dev/null || true
            git pull --ff-only 2>/dev/null || true
            continue
        fi

        success "#$num fix/ship complete"
        report_issue "$num"

        # ── Stage 2: Verify (ready_for_test → verified) ──
        cd "$PROJECT_ROOT"
        git checkout main 2>/dev/null || true
        git pull --ff-only 2>/dev/null || true

        if [[ -f "${SCRIPT_DIR}/verify-issue.sh" ]]; then
            info "[Stage 2/3] verify-issue.sh #$num"
            if bash "${SCRIPT_DIR}/verify-issue.sh" "$num" --auto --model sonnet 2>&1 | tee -a "$LOG_FILE"; then
                success "#$num verified"
            else
                warn "#$num verification failed — stopping pipeline for this issue"
                TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
                TOTAL_PROCESSED=$(( TOTAL_PROCESSED + 1 ))
                cd "$PROJECT_ROOT"
                git checkout main 2>/dev/null || true
                git pull --ff-only 2>/dev/null || true
                continue
            fi
        else
            info "[Stage 2/3] verify-issue.sh not found — skipping verification"
        fi

        # ── Stage 3: Merge PR + Close (verified → closed) ──
        cd "$PROJECT_ROOT"
        git checkout main 2>/dev/null || true
        git pull --ff-only 2>/dev/null || true

        info "[Stage 3/3] Merge PR + close #$num"
        local pr_num=$(gh pr list --state open --json number,title,body \
            --jq ".[] | select(.body | contains(\"#${num}\")) | .number" 2>/dev/null | head -1)

        if [[ -n "$pr_num" ]]; then
            if gh pr merge "$pr_num" --squash --delete-branch 2>/dev/null; then
                success "PR #$pr_num merged (squash) — #$num auto-closed"
            elif gh pr merge "$pr_num" --squash --auto --delete-branch 2>/dev/null; then
                success "PR #$pr_num auto-merge enabled — will merge when checks pass"
            else
                warn "PR #$pr_num merge failed — needs manual merge"
            fi
        else
            gh issue close "$num" 2>/dev/null || warn "Failed to close #$num"
            success "Closed #$num (no PR found)"
        fi

        report_issue "$num"

        local issue_end=$(date +%s)
        success "#$num full pipeline complete ($(( issue_end - issue_start ))s)"
        TOTAL_SUCCEEDED=$(( TOTAL_SUCCEEDED + 1 ))
        TOTAL_PROCESSED=$(( TOTAL_PROCESSED + 1 ))

        # Reset to latest main before next issue
        cd "$PROJECT_ROOT"
        git checkout main 2>/dev/null || true
        git pull --ff-only 2>/dev/null || true

        if [[ $TOTAL_PROCESSED -ge $LIMIT ]]; then
            info "Reached limit ($LIMIT) — stopping"
            break
        fi
    done
}

process_issues_by_label() {
    local label="$1"
    local flags="$2"
    local processed=0

    info "Scanning issues with label: $label"

    # Fetch issues with labels for routing (--sort controls order)
    local sort_flag=""
    case "$SORT_ORDER" in
        oldest) sort_flag="--sort created --order asc" ;;
        *)      sort_flag="--sort created --order desc" ;;  # newest (default)
    esac
    local issues=$(gh issue list --label "$label" --label "pipeline" --state open --json number,title,labels --limit "$((LIMIT * 2))" $sort_flag 2>/dev/null || echo "[]")

    # Filter out WONTFIX/WONTFEAT and separate bugs vs features
    local bugs=$(echo "$issues" | jq '[.[] | select(.title | ascii_upcase | contains("[BUG]"))]')
    local features=$(echo "$issues" | jq '[.[] | select(.title | ascii_upcase | (contains("[BUG]") | not) and (contains("[WONTFIX]") | not) and (contains("[WONTFEAT]") | not))]')
    local skipped=$(echo "$issues" | jq '[.[] | select(.title | ascii_upcase | (contains("[WONTFIX]") or contains("[WONTFEAT]")))]')

    local skip_count=$(echo "$skipped" | jq 'length')
    local bug_count=$(echo "$bugs" | jq 'length')
    local feat_count=$(echo "$features" | jq 'length')

    if [[ "$skip_count" -gt 0 ]]; then
        warn "Skipping $skip_count WONTFIX/WONTFEAT issue(s)"
        TOTAL_SKIPPED=$(( TOTAL_SKIPPED + skip_count ))
    fi

    if [[ "$bug_count" -eq 0 ]] && [[ "$feat_count" -eq 0 ]]; then
        info "No actionable issues found with label: $label"
        return 0
    fi

    info "Found $bug_count bug(s) + $feat_count feature(s) with label: $label"

    # Process bugs first (priority per CLAUDE.md), then features
    local ordered=$(echo "$bugs $features" | jq -s 'add')

    for row in $(echo "$ordered" | jq -r '.[] | @base64'); do
        local num=$(echo "$row" | base64 --decode | jq -r '.number')
        local title=$(echo "$row" | base64 --decode | jq -r '.title')
        local labels_json=$(echo "$row" | base64 --decode | jq '.labels')
        local issue_type=$(get_issue_type "$title")
        local script=$(get_script_for_type "$issue_type")

        if [[ -z "$script" ]]; then
            warn "Skipping #$num: $title (WONTFIX/WONTFEAT)"
            TOTAL_SKIPPED=$(( TOTAL_SKIPPED + 1 ))
            continue
        fi

        # Build smart flags from labels + title prefix
        local issue_flags=$(build_issue_flags "$flags" "$title" "$labels_json")
        local flag_summary=$(build_flag_summary "$title" "$labels_json")

        info "Processing #$num ($issue_type → $script ${flag_summary}): $title"

        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY RUN] Would run: ${SCRIPT_DIR}/$script $num $issue_flags"
        else
            local issue_start=$(date +%s)
            cd "$PROJECT_ROOT"

            if bash "${SCRIPT_DIR}/${script}" "$num" $issue_flags 2>&1 | tee -a "$LOG_FILE"; then
                local issue_end=$(date +%s)
                local issue_duration=$(( issue_end - issue_start ))
                success "#$num completed (${issue_duration}s)"
                TOTAL_SUCCEEDED=$(( TOTAL_SUCCEEDED + 1 ))
                # Post-fix/ship: report to Slack
                report_issue "$num"
            else
                local issue_end=$(date +%s)
                local issue_duration=$(( issue_end - issue_start ))
                warn "#$num failed (${issue_duration}s)"
                TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
            fi

            # Reset to latest main before next issue
            cd "$PROJECT_ROOT"
            git checkout main 2>/dev/null || true
            git pull --ff-only 2>/dev/null || true
        fi

        TOTAL_PROCESSED=$(( TOTAL_PROCESSED + 1 ))

        if [[ $TOTAL_PROCESSED -ge $LIMIT ]]; then
            info "Reached limit ($LIMIT) — stopping"
            break
        fi
    done
}

# ------------------------------------------------------------------------------
# Label → Action Routing
# ------------------------------------------------------------------------------

route_by_label() {
    local label="$1"
    local extra_flags="${PROFILE_FLAGS:-}"

    case "$label" in
        ready_for_dev)
            # Model routing (Issue 07): sonnet default for fixes, opus via --hard label
            process_issues_by_label "ready_for_dev" "--auto $extra_flags"
            ;;
        ready_for_test)
            # E2E verification — no fix/ship needed, route directly to verify-issue.sh
            info "Processing ready_for_test issues..."
            local test_issues=$(gh issue list --label "ready_for_test" --label "pipeline" --state open --json number,title --limit "$LIMIT" 2>/dev/null || echo "[]")
            local test_count=$(echo "$test_issues" | jq 'length')

            if [[ "$test_count" -eq 0 ]]; then
                info "No issues found with label: ready_for_test"
            else
                info "Found $test_count issue(s) to verify"
                for row in $(echo "$test_issues" | jq -r '.[] | @base64'); do
                    local num=$(echo "$row" | base64 --decode | jq -r '.number')
                    local title=$(echo "$row" | base64 --decode | jq -r '.title')

                    info "Verifying #$num: $title"

                    if [[ "$DRY_RUN" == "true" ]]; then
                        info "[DRY RUN] Would run: verify-issue.sh $num --model sonnet $extra_flags"
                    else
                        local issue_start=$(date +%s)
                        cd "$PROJECT_ROOT"

                        if bash "${SCRIPT_DIR}/verify-issue.sh" "$num" --auto --model sonnet $extra_flags 2>&1 | tee -a "$LOG_FILE"; then
                            local issue_end=$(date +%s)
                            success "#$num verified ($(( issue_end - issue_start ))s)"
                            TOTAL_SUCCEEDED=$(( TOTAL_SUCCEEDED + 1 ))
                        else
                            local issue_end=$(date +%s)
                            warn "#$num verification failed ($(( issue_end - issue_start ))s)"
                            TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
                        fi

                        cd "$PROJECT_ROOT"
                        git checkout main 2>/dev/null || true
                        git pull --ff-only 2>/dev/null || true
                    fi

                    TOTAL_PROCESSED=$(( TOTAL_PROCESSED + 1 ))
                    if [[ $TOTAL_PROCESSED -ge $LIMIT ]]; then
                        info "Reached limit ($LIMIT) — stopping"
                        break
                    fi
                done
            fi
            ;;
        verified)
            # Merge linked PR (squash) then close issue
            info "Processing verified issues..."
            local issues=$(gh issue list --label "verified" --state open --json number --limit "$LIMIT" 2>/dev/null || echo "[]")
            for row in $(echo "$issues" | jq -r '.[] | @base64'); do
                local num=$(echo "$row" | base64 --decode | jq -r '.number')
                if [[ "$DRY_RUN" == "true" ]]; then
                    info "[DRY RUN] Would merge PR + close issue #$num"
                else
                    # Find open PR linked to this issue number
                    local pr_num=$(gh pr list --state open --json number,title,body \
                        --jq ".[] | select(.body | contains(\"#${num}\")) | .number" 2>/dev/null | head -1)

                    if [[ -n "$pr_num" ]]; then
                        info "Merging PR #$pr_num for issue #$num..."
                        # PR body has "Closes #N" — GitHub auto-closes issue on merge
                        # Try direct merge first; fall back to --auto if checks are pending
                        if gh pr merge "$pr_num" --squash --delete-branch 2>/dev/null; then
                            success "PR #$pr_num merged (squash) — issue #$num will auto-close"
                            report_issue "$num"
                        elif gh pr merge "$pr_num" --squash --auto --delete-branch 2>/dev/null; then
                            success "PR #$pr_num auto-merge enabled — will merge when checks pass"
                        else
                            warn "PR #$pr_num merge failed — close manually"
                        fi
                    else
                        # No PR found (e.g. fix went directly to main) — close issue manually
                        gh issue close "$num" 2>/dev/null || warn "Failed to close #$num"
                        success "Closed #$num"
                        report_issue "$num"
                    fi
                fi
            done
            ;;
        blocked)
            # Log blocked issues, skip
            local issues=$(gh issue list --label "blocked" --state open --json number,title --limit 50 2>/dev/null || echo "[]")
            local count=$(echo "$issues" | jq 'length')
            warn "$count blocked issue(s) — skipping"
            ;;
        *)
            warn "Unknown label: $label"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    info "=========================================="
    info "Looper Pipeline Scanner"
    info "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    [[ -n "$PROFILE" ]] && info "Profile: $PROFILE"
    [[ -n "$ISSUE_LIST" ]] && info "Issue list: $ISSUE_LIST"
    [[ -n "$FILTER_LABEL" ]] && info "Label filter: $FILTER_LABEL"
    [[ "$SORT_ORDER" != "newest" ]] && info "Sort: $SORT_ORDER"
    [[ "$DRY_RUN" == "true" ]] && info "Mode: DRY RUN"
    info "Limit: $LIMIT issues per label"
    info "=========================================="

    cd "$PROJECT_ROOT"

    # Acquire lock (prevents concurrent runs)
    acquire_lock

    # Load profile if specified
    [[ -n "$PROFILE" ]] && load_profile

    # Print summary if profile requests it or morning profile
    if [[ "$PROFILE_SUMMARY" == "true" ]]; then
        print_summary
    fi

    # Phase 0: Read Slack for new tasks (if --read-slack)
    if [[ "$READ_SLACK" == "true" ]]; then
        read_slack_tasks
    fi

    # Phase 0.5: Brainstorm tasks into GitHub issues (if --brainstorm-prd)
    if [[ "$BRAINSTORM_PRD" == "true" ]]; then
        brainstorm_prd_tasks
    fi

    # Standalone phases — stop here, don't continue to label scan
    if [[ "$READ_SLACK" == "true" || "$BRAINSTORM_PRD" == "true" ]]; then
        return
    fi

    # Route: explicit issues → label filter → scan all
    if [[ -n "$ISSUE_LIST" ]]; then
        # Explicit issue list — process in exact order given
        local extra_flags="${PROFILE_FLAGS:-}"
        process_explicit_issues "--auto $extra_flags"
    elif [[ -n "$FILTER_LABEL" ]]; then
        # Handle comma-separated labels
        IFS=',' read -ra LABELS <<< "$FILTER_LABEL"
        for label in "${LABELS[@]}"; do
            route_by_label "$(echo "$label" | xargs)"  # trim whitespace
        done
    else
        # Default: process all pipeline stages in order
        route_by_label "ready_for_dev"
        route_by_label "ready_for_test"
        route_by_label "verified"
        route_by_label "blocked"
    fi

    # Print results
    print_run_results
    print_summary

    # Transform all .log files to .md for better readability
    transform_logs

    success "Looper scan complete"
    info "Log: $LOG_FILE"
}

main
