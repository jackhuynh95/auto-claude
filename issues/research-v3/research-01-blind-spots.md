# Research 01: Blind Spots — Gaps Each Analysis Missed

## Gaps the Screenshot Raises That V2 Didn't Cover

### Gap A: tmux Orphan Reaper (CRITICAL)

**Screenshot's warning**: "If the Lead crashes without cleaning up, you get 'orphaned' invisible tmux sessions draining resources."

**V2's omission**: V2 proposes `spawn-worker.sh` creating tmux sessions but has no cleanup mechanism if `swarm-commander.sh` crashes mid-run.

**V3 fix**: Add a reaper function to `swarm-commander.sh`:
```bash
cleanup_workers() {
    # Kill all worker tmux sessions
    tmux list-sessions 2>/dev/null | grep "^worker-" | cut -d: -f1 | while read session; do
        tmux kill-session -t "$session" 2>/dev/null
        warn "Killed orphaned session: $session"
    done
    # Clean up worktrees
    git worktree list | grep "/tmp/swarm-worker-" | awk '{print $1}' | while read wt; do
        git worktree remove --force "$wt" 2>/dev/null
    done
}
trap cleanup_workers EXIT SIGINT SIGTERM
```

**Also**: Add a standalone `reap-workers.sh` (~15 LOC) for manual cleanup when the commander itself crashes:
```bash
#!/bin/bash
# reap-workers.sh — emergency cleanup for orphaned swarm workers
tmux list-sessions 2>/dev/null | grep "^worker-" | cut -d: -f1 | while read s; do
    echo "Killing: $s"
    tmux kill-session -t "$s"
done
git worktree list | grep "/tmp/swarm-worker-" | awk '{print $1}' | while read wt; do
    echo "Removing worktree: $wt"
    git worktree remove --force "$wt" 2>/dev/null
done
echo "Cleanup complete."
```

### Gap B: Per-Worker Cost Accumulation

**Screenshot's warning**: agent-teams burns through API credits fast because every teammate has its own context window.

**V2's mention**: Listed cost tracking as P2 (low priority). But for parallel workers, it becomes P1.

**V3 fix**: Each worker should write token usage to its status JSON:
```json
{
  "issue": 42,
  "status": "done",
  "exit": 0,
  "tokens_in": 15230,
  "tokens_out": 4891,
  "duration_sec": 342,
  "model": "sonnet"
}
```

`swarm-commander.sh` sums across workers and logs total:
```bash
total_tokens=$(jq -s '[.[].tokens_in + .[].tokens_out] | add' logs/worker-*-status.json)
info "Total token usage this run: $total_tokens"
```

### Gap C: Dead Worker Detection (Heartbeat)

**Screenshot's implicit concern**: How do you know a worker is alive vs hung?

**V2's assumption**: Poll status JSON files. But if a worker hangs (Claude CLI frozen), the status stays "running" forever.

**V3 fix**: Workers write a heartbeat timestamp every 60s:
```bash
# In spawn-worker.sh, background heartbeat alongside the main script
while true; do
    jq '.heartbeat = "'$(date -Iseconds)'"' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sleep 60
done &
HEARTBEAT_PID=$!
```

Commander checks heartbeat age:
```bash
last_beat=$(jq -r '.heartbeat' "$STATUS_FILE")
age_sec=$(( $(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%S" "$last_beat" +%s 2>/dev/null || echo 0) ))
if [[ $age_sec -gt 300 ]]; then
    warn "Worker $issue appears hung (no heartbeat for ${age_sec}s) — killing"
    tmux kill-session -t "worker-${issue}" 2>/dev/null
fi
```

---

## Gaps V2 Found That the Screenshot Ignores

### V2 Gap 1: Spin Detection (Still Valid)

The screenshot doesn't address the real-world problem of Claude producing identical output across retries. V2's hash-based spin detection (P1) remains important.

**Status**: Still a V2 recommendation. Not changed by V3.

### V2 Gap 2: Git Conflict Detection Between Parallel PRs (Still Valid)

The screenshot mentions nothing about file-level conflicts when parallel workers create separate PRs. V2's `git merge-tree` proposal remains the right approach.

**Status**: Still a V2 recommendation. Upgraded to P1 for parallel mode.

### V2 Gap 3: Build Validation Regex Brittleness (Still Valid)

V2 noted `grep -qi "error"` matching "errorHandler" in success output. Screenshot doesn't address build validation at all.

**Status**: Low priority. Works well enough for 90%+ of cases.

---

## Combined Priority Matrix (V2 + V3)

| ID | Gap | Source | Priority | LOC Estimate |
|---|---|---|---|---|
| P0 | Wall-clock timeout | V2 | **P0** | ~5 per script |
| P1a | Spin detection | V2 | **P1** | ~8 |
| P1b | tmux orphan reaper | V3 (screenshot) | **P1** | ~15 (reap-workers.sh) + trap in commander |
| P1c | Per-worker cost tracking | V3 (screenshot) | **P1** | ~10 in spawn-worker + ~5 in commander |
| P1d | Git conflict detection | V2 (upgraded) | **P1** | ~12 |
| P2 | Dead worker heartbeat | V3 (screenshot) | **P2** | ~15 in spawn-worker + ~8 in commander |
| P3 | Build regex fix | V2 | **P3** | ~3 |

**Total new LOC for all gaps: ~80 lines** (on top of V2's ~120 for spawn-worker + swarm-commander = ~200 total).
