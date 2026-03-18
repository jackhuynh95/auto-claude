# Research 02: Revised Swarm Design (V2 + Screenshot Insights)

## What Changed from V2

V2 proposed 2 new scripts (~120 LOC). V3 adds 1 more script and expands the other two:

| Component | V2 Proposal | V3 Revision | Why |
|---|---|---|---|
| `spawn-worker.sh` | ~40 LOC | ~55 LOC | Added: heartbeat loop, cost extraction, crash trap |
| `swarm-commander.sh` | ~80 LOC | ~95 LOC | Added: orphan reaper trap, dead-worker detection, cost summary |
| `reap-workers.sh` | Not proposed | ~15 LOC (**NEW**) | Emergency cleanup when commander itself crashes |
| **Total** | **~120 LOC** | **~165 LOC** | +45 LOC for robustness |

## Revised Architecture

```
┌──────────────────────────────────────────────────────────┐
│  /loop 2h ./looper.sh --profile overnight --parallel      │  ← --parallel is new
└───────────────┬──────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────┐
│  looper.sh                                                │
│                                                           │
│  if --parallel:                                           │
│    └── swarm-commander.sh                                 │
│         ├── trap cleanup_workers EXIT/SIGINT/SIGTERM ←NEW │
│         ├── spawn-worker.sh "fix-issue.sh" 42 --auto      │
│         ├── spawn-worker.sh "ship-issue.sh" 15 --auto     │
│         ├── spawn-worker.sh "verify-issue.sh" 7 --auto    │
│         ├── poll loop (check status JSON + heartbeat) ←NEW│
│         └── cost summary on exit ←NEW                     │
│  else:                                                    │
│    └── process_issues_by_label (existing serial path)     │
└──────────────────────────────────────────────────────────┘

Each spawn-worker.sh creates:
┌──────────────────────────────────────┐
│  tmux session: worker-{issue}         │
│  worktree: /tmp/swarm-worker-{issue}  │
│  status: logs/worker-{issue}.json     │
│  heartbeat: every 60s in status JSON  │  ←NEW
│  cost: tokens written to status JSON  │  ←NEW
│  trap: cleanup worktree on exit       │  ←NEW
└──────────────────────────────────────┘
```

## Revised spawn-worker.sh

```bash
#!/bin/bash
# spawn-worker.sh <script> <issue-num> [flags...]
set -euo pipefail

SCRIPT="$1"; ISSUE="$2"; shift 2
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/tmp/swarm-worker-${ISSUE}"
SESSION="worker-${ISSUE}"
STATUS_FILE="${SCRIPT_DIR}/logs/worker-${ISSUE}-status.json"

# Cleanup function
cleanup() {
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    git -C "${SCRIPT_DIR}" worktree remove --force "$WORKTREE" 2>/dev/null || true
}

# Create worktree
git worktree add "$WORKTREE" -b "swarm-${ISSUE}" main 2>/dev/null || {
    echo "Failed to create worktree for issue $ISSUE"
    exit 1
}

# Write initial status
cat > "$STATUS_FILE" <<EOF
{"issue":${ISSUE},"status":"running","start":"$(date -Iseconds)","heartbeat":"$(date -Iseconds)"}
EOF

# Heartbeat loop (background)
(
    while true; do
        sleep 60
        jq --arg hb "$(date -Iseconds)" '.heartbeat = $hb' "$STATUS_FILE" > "${STATUS_FILE}.tmp" \
            && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    done
) &
HEARTBEAT_PID=$!

# Launch in tmux
tmux new-session -d -s "$SESSION" -c "$WORKTREE" \
    "trap 'kill $HEARTBEAT_PID 2>/dev/null' EXIT; \
     bash ${SCRIPT_DIR}/${SCRIPT} ${ISSUE} $@ --worktree; \
     EXIT_CODE=\$?; \
     jq --arg end \"\$(date -Iseconds)\" --arg exit \"\$EXIT_CODE\" \
        '.status=\"done\" | .end=\$end | .exit=(\$exit|tonumber)' \
        \"$STATUS_FILE\" > \"${STATUS_FILE}.tmp\" && mv \"${STATUS_FILE}.tmp\" \"$STATUS_FILE\"; \
     exit \$EXIT_CODE"

echo "Spawned worker for issue #${ISSUE} in tmux session '${SESSION}'"
```

## Revised swarm-commander.sh (Key Additions)

```bash
#!/bin/bash
# swarm-commander.sh — manages parallel worker pool
set -euo pipefail

MAX_WORKERS=${MAX_WORKERS:-3}
POLL_INTERVAL=${POLL_INTERVAL:-30}
HEARTBEAT_TIMEOUT=${HEARTBEAT_TIMEOUT:-300}  # 5 min
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# CRITICAL: Clean up all workers on exit (addresses screenshot's orphan concern)
cleanup_workers() {
    warn "Commander exiting — cleaning up workers..."
    tmux list-sessions 2>/dev/null | grep "^worker-" | cut -d: -f1 | while read session; do
        tmux kill-session -t "$session" 2>/dev/null
        warn "Killed session: $session"
    done
    git worktree list | grep "/tmp/swarm-worker-" | awk '{print $1}' | while read wt; do
        git worktree remove --force "$wt" 2>/dev/null
    done
}
trap cleanup_workers EXIT SIGINT SIGTERM

# Dead worker detection (addresses screenshot's "hung agent" concern)
check_worker_health() {
    local issue=$1
    local status_file="${SCRIPT_DIR}/logs/worker-${issue}-status.json"
    local status=$(jq -r '.status' "$status_file" 2>/dev/null)

    if [[ "$status" == "running" ]]; then
        local last_beat=$(jq -r '.heartbeat // empty' "$status_file" 2>/dev/null)
        if [[ -n "$last_beat" ]]; then
            local now=$(date +%s)
            local beat_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$last_beat" +%s 2>/dev/null || echo 0)
            local age=$(( now - beat_epoch ))
            if [[ $age -gt $HEARTBEAT_TIMEOUT ]]; then
                warn "Worker #${issue} hung (no heartbeat for ${age}s) — killing"
                tmux kill-session -t "worker-${issue}" 2>/dev/null
                jq '.status = "killed" | .reason = "heartbeat_timeout"' "$status_file" > "${status_file}.tmp" \
                    && mv "${status_file}.tmp" "$status_file"
                return 1
            fi
        fi
    fi
    return 0
}

# Cost summary (addresses screenshot's "token burn" concern)
print_cost_summary() {
    info "=== Swarm Cost Summary ==="
    local total_in=0 total_out=0
    for f in "${SCRIPT_DIR}"/logs/worker-*-status.json; do
        [[ -f "$f" ]] || continue
        local issue=$(jq -r '.issue' "$f")
        local tokens_in=$(jq -r '.tokens_in // 0' "$f")
        local tokens_out=$(jq -r '.tokens_out // 0' "$f")
        local status=$(jq -r '.status' "$f")
        info "  #${issue}: ${status} | in:${tokens_in} out:${tokens_out}"
        total_in=$((total_in + tokens_in))
        total_out=$((total_out + tokens_out))
    done
    info "  TOTAL: in:${total_in} out:${total_out}"
}

# Main poll loop with health checks
# ... (issue fetching + spawn logic same as V2)
# ... (add check_worker_health calls in poll loop)
# ... (call print_cost_summary before exit)
```

## reap-workers.sh (NEW — Emergency Cleanup)

```bash
#!/bin/bash
# reap-workers.sh — manual cleanup when commander crashes
# Run this if you see orphaned "worker-*" tmux sessions
echo "=== Reaping orphaned swarm workers ==="

count=0
tmux list-sessions 2>/dev/null | grep "^worker-" | cut -d: -f1 | while read s; do
    echo "  Killing tmux session: $s"
    tmux kill-session -t "$s"
    ((count++))
done

git worktree list | grep "/tmp/swarm-worker-" | awk '{print $1}' | while read wt; do
    echo "  Removing worktree: $wt"
    git worktree remove --force "$wt" 2>/dev/null
done

# Clean stale status files
for f in logs/worker-*-status.json; do
    [[ -f "$f" ]] || continue
    status=$(jq -r '.status' "$f" 2>/dev/null)
    if [[ "$status" == "running" ]]; then
        jq '.status = "reaped" | .reason = "manual_reap"' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        echo "  Marked as reaped: $f"
    fi
done

echo "=== Reap complete ==="
```

## Revised Phased Rollout

### Phase 1: Safety Hardening (Before Any Parallelism)
- Wall-clock timeout on `run_claude` calls (V2 P0)
- Spin detection via output hashing (V2 P1)
- `reap-workers.sh` standalone script (V3 — available before swarm exists, useful for manual tmux cleanup)

### Phase 2: Worker Isolation (Low Risk)
- `spawn-worker.sh` with heartbeat + crash trap
- Test with 1 worker (functionally serial, but validates isolation)

### Phase 3: Parallel Commander (Medium Risk)
- `swarm-commander.sh` with orphan reaper + dead-worker detection
- `looper.sh --parallel` flag
- MAX_WORKERS=2 initially (conservative)
- Cost summary in output

### Phase 4: Production Parallel (After Validation)
- Bump MAX_WORKERS=3
- Add git conflict detection (V2 P1d)
- Morning profile prints overnight swarm summary with cost breakdown

## Design Decisions Log

| Decision | Chose | Over | Why |
|---|---|---|---|
| Communication protocol | JSON status files | Native mailbox (`~/.claude/tasks/`) | Portable, debuggable, works with any CLI tool |
| Worker isolation | tmux + git worktree | Background processes | Inspectable, killable, output preserved |
| Orphan handling | trap + standalone reaper | Rely on manual cleanup | Screenshot correctly flagged this as critical |
| Cost tracking | Per-worker JSON field | Centralized counter | Each worker is independent; commander aggregates |
| Heartbeat | File-based timestamp | Process signal ping | Simpler, works across tmux sessions |
