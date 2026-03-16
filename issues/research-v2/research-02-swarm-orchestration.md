# Research 02: Swarm Orchestration — A tmux-Based Parallel Worker System

## Why tmux, Not Background Processes

Background processes (`&`, `nohup`, `disown`) lose output, are hard to inspect, and die when the parent shell exits. tmux gives us:

- **Live inspection**: `tmux attach -t worker-42` to watch a fix in progress
- **Detach/reattach**: Walk away, come back, output is still there
- **Named sessions**: `worker-fix-42`, `worker-ship-15` — self-documenting
- **Kill with confidence**: `tmux kill-session -t worker-42` is clean

## Architecture: 3 New Scripts, 0 Rewrites

```
looper.sh (existing — add --parallel flag)
  └── swarm-commander.sh (NEW — replaces serial loop when --parallel)
       ├── spawn-worker.sh "fix-issue.sh" 42 --auto
       ├── spawn-worker.sh "ship-issue.sh" 15 --auto
       └── spawn-worker.sh "verify-issue.sh" 7 --auto
            └── (each runs in its own tmux pane + git worktree)
```

### spawn-worker.sh
```bash
#!/bin/bash
# spawn-worker.sh <script> <issue-num> [flags...]
# Creates a tmux session, git worktree, runs the script, writes status JSON.

SCRIPT="$1"; ISSUE="$2"; shift 2
WORKTREE="/tmp/swarm-worker-${ISSUE}"
SESSION="worker-${ISSUE}"
STATUS_FILE="logs/worker-${ISSUE}-status.json"

# Create worktree
git worktree add "$WORKTREE" -b "swarm-${ISSUE}" main 2>/dev/null

# Write initial status
echo '{"issue":'$ISSUE',"status":"running","start":"'$(date -Iseconds)'"}' > "$STATUS_FILE"

# Launch in tmux
tmux new-session -d -s "$SESSION" -c "$WORKTREE" \
  "bash $SCRIPT $ISSUE $@ --worktree; \
   echo '{\"issue\":$ISSUE,\"status\":\"done\",\"exit\":'$?',\"end\":\"'$(date -Iseconds)'\"}' > $STATUS_FILE"
```

### swarm-commander.sh
```bash
#!/bin/bash
# swarm-commander.sh — poll worker status files, collect results, clean up.
# Called by looper.sh when --parallel is set.

MAX_WORKERS=3  # concurrent worker cap
POLL_INTERVAL=30  # seconds between status checks

# 1. Fetch issues (same logic as looper.sh)
# 2. Spawn up to MAX_WORKERS via spawn-worker.sh
# 3. Poll status JSON files every POLL_INTERVAL
# 4. When a worker finishes, spawn next issue (if any)
# 5. When all done, collect results and return summary
```

### Key Constraint: Worker Slot Pool
Don't spawn unbounded workers. Use a simple counter:
```bash
active_count=$(tmux list-sessions 2>/dev/null | grep -c "^worker-" || echo 0)
if [[ $active_count -ge $MAX_WORKERS ]]; then
    info "Worker pool full ($MAX_WORKERS) — waiting..."
fi
```

## CLI Agnosticism (Model Routing Per Worker)

The existing model routing in `fix-issue.sh` (sonnet/opus) already supports `--model` and `--codex`/`--opencode` flags. For swarm mode, this extends naturally:

| Worker Type | Default CLI | Why |
|---|---|---|
| Bug fix (standard) | Claude Sonnet | Cheap, fast, good enough for 80% of bugs |
| Bug fix (hard label) | Claude Opus | Needs deeper reasoning |
| Feature ship | Claude Opus (plan) + Sonnet (code) | Already split in ship-issue.sh |
| E2E verify | Claude Sonnet | Execution-only task |
| Fallback (after 3 retries) | Codex GPT-5.2 | Different model may see different solution |

**Future**: Add Gemini CLI routing for research-heavy issues (wide context window for large codebases).

## Worker Specialization Roles

Not all workers should run the same way. The label system already enables this:

| Label Combination | Effective Worker Config |
|---|---|
| `ready_for_dev` + `[BUG]` | `fix-issue.sh --auto` (sonnet) |
| `ready_for_dev` + `[BUG]` + `hard` | `fix-issue.sh --auto --hard` (opus) |
| `ready_for_dev` + `[FEATURE]` | `ship-issue.sh --auto` (opus+sonnet) |
| `ready_for_dev` + `[FEATURE]` + `frontend` | `ship-issue.sh --auto --frontend-design` |
| `ready_for_test` | `verify-issue.sh --auto` (sonnet) |
| `verified` | Direct merge via `gh pr merge` (no Claude needed) |

The swarm doesn't need "roles" as a concept — **labels are already the roles**.

## Conflict Resolution Strategy

Parallel workers on separate issues can create PRs that conflict:

1. **Prevention**: `looper.sh` already processes bugs before features. In parallel, assign a rough file-scope heuristic — if two issues mention the same file in their body, serialize them.
2. **Detection**: After all workers finish, run `git merge-tree` on each PR branch pair to detect conflicts.
3. **Resolution**: If conflicts, keep the bug-fix PR, re-queue the feature for next cycle.

## Phased Rollout

### Phase 1: Observability (No Code Changes)
- Add wall-clock timeout to `run_claude` calls
- Add spin detection (output hashing)
- Track per-issue duration in looper results

### Phase 2: tmux Visibility (Low Risk)
- `spawn-worker.sh` wraps existing scripts in tmux
- `looper.sh --parallel` flag routes to swarm-commander instead of serial loop
- Still serial by default; parallel is opt-in

### Phase 3: True Parallel (Medium Risk)
- Worker slot pool (MAX_WORKERS=3)
- Status JSON protocol for inter-process communication
- Conflict detection after workers complete
- Morning profile prints "overnight swarm summary" with all worker results
