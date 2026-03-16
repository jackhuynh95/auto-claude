# Research 03: Bash Architecture — Current State + Evolution Path

## Actual Architecture Today

```
┌─────────────────────────────────────────────────────────┐
│  /loop 2h ./looper.sh --profile overnight               │  ← Claude Code built-in
└───────────────┬─────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────┐
│  looper.sh                                               │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Lock file → Profile loading → Label scan            │ │
│  │                                                     │ │
│  │ ready_for_dev ──┬── [BUG]     → fix-issue.sh       │ │
│  │                 ├── [FEATURE] → ship-issue.sh      │ │
│  │                 ├── [DOCS]    → ship-issue.sh --no-test │
│  │                 └── [WONTFIX] → skip               │ │
│  │                                                     │ │
│  │ ready_for_test ──── verify-issue.sh                 │ │
│  │                                                     │ │
│  │ verified ────────── gh pr merge --squash            │ │
│  │                                                     │ │
│  │ blocked ─────────── log & skip                      │ │
│  └─────────────────────────────────────────────────────┘ │
│  Results → Summary → .log→.md transform                  │
└──────────────────────────────────────────────────────────┘
                │
    ┌───────────┼───────────┐
    ▼           ▼           ▼
fix-issue.sh  ship-issue.sh  verify-issue.sh
┌──────────┐ ┌───────────┐ ┌──────────────┐
│ Branch   │ │ Branch    │ │ PR checkout  │
│ /debug   │ │ /plan     │ │ Health check │
│ /fix     │ │ /code     │ │ /test:e2e    │
│ /test    │ │ Commit    │ │ Label → ✓/✗  │
│ Retry×3  │ │ PR        │ │ Back to main │
│ Fallback │ │ Label     │ └──────────────┘
│ Commit   │ └───────────┘
│ PR       │
└──────────┘
```

## What Bash Gives Us (That Other Languages Don't)

1. **Direct CLI composition**: `claude -p "..." | tee -a "$LOG_FILE"` — no SDK, no wrapper library, no dependency
2. **Process model**: Each script is a process. tmux gives us session management. `timeout` gives us wall clocks. `trap` gives us cleanup.
3. **gh/git native**: No GitHub API wrapper needed. `gh issue list --json` + `jq` is the query language.
4. **Zero deploy**: No `npm install`, no virtual env, no build step. Clone and run.
5. **Composability**: `fix-issue.sh 42 --auto --hard --worktree --e2e` — flags compose naturally

## Where Bash Starts Breaking Down

| Symptom | When It Hits | Mitigation |
|---|---|---|
| JSON parsing | When status files need nested objects | Keep status JSON flat. Use `jq` sparingly. |
| String quoting | Issue titles with quotes/special chars break `echo "$ISSUE_TITLE"` | Already handled — `jq -r` does safe extraction |
| Error handling | `set -euo pipefail` catches most issues, but `||` chains get unreadable at depth | Extract into well-named functions (already done) |
| State management | Sharing state between spawned workers | File-based protocol (JSON status files) — Bash's natural IPC |
| Testing | No unit test framework for Bash | Integration tests only: run script, check exit code + output |

**Verdict**: Bash holds for the next 2-3 evolution steps. The tipping point is when worker coordination needs shared data structures (queues, priority heaps). That's when a thin Python/Node coordinator makes sense — but the workers should stay as Bash scripts.

## Evolution Path (Concrete Steps)

### Step 1: Add Missing Safety (Now)
Files to modify: `fix-issue.sh`, `ship-issue.sh`

```bash
# In run_claude() — add timeout
timeout ${CLAUDE_TIMEOUT:-600} claude -p "$prompt" $flags $MODEL_FLAG ...

# In step_2_fix() — add spin detection
local output_hash=$(echo "$output" | md5 -q)
[[ "$output_hash" == "$PREV_HASH" ]] && { warn "Spin detected"; break; }
PREV_HASH="$output_hash"
```

### Step 2: Worker Wrapper (Next)
New file: `spawn-worker.sh` (~40 lines)

- Takes a script + issue + flags
- Creates git worktree at `/tmp/swarm-worker-{issue}`
- Launches in tmux session `worker-{issue}`
- Writes `logs/worker-{issue}-status.json` on completion

### Step 3: Parallel Commander (After)
New file: `swarm-commander.sh` (~80 lines)

- Reads issue list from `looper.sh`
- Manages worker pool (MAX_WORKERS slots)
- Polls `logs/worker-*-status.json` for completion
- Spawns new workers as slots free up
- Collects and prints summary

### Step 4: Integration with looper.sh
Modified: `looper.sh` — add `--parallel` flag

```bash
if [[ "$PARALLEL" == "true" ]]; then
    bash "${SCRIPT_DIR}/swarm-commander.sh" "$label" "$flags" --limit "$LIMIT"
else
    process_issues_by_label "$label" "$flags"  # existing serial path
fi
```

## The Bash vs Python Question

**When to move coordination to Python/Node**:
- When you need a persistent queue (Redis-backed or SQLite)
- When you need webhook receivers (GitHub → trigger worker)
- When status polling needs to become event-driven

**When to keep workers in Bash**:
- Always. The worker scripts (`fix-issue.sh`, etc.) call CLI tools. Wrapping them in Python adds nothing except a subprocess call. Bash IS the right language for "run CLI, check exit code, log output."

## Component Inventory (Current + Proposed)

| Component | Status | Lines | Purpose |
|---|---|---|---|
| `looper.sh` | Exists | 574 | Commander, label scanner, profile loader |
| `fix-issue.sh` | Exists | 752 | Bug fix workflow |
| `ship-issue.sh` | Exists | 629 | Feature ship workflow |
| `verify-issue.sh` | Exists | 211 | E2E verification |
| `spawn-worker.sh` | **Proposed** | ~40 | tmux + worktree wrapper |
| `swarm-commander.sh` | **Proposed** | ~80 | Parallel worker pool manager |
| `looper-profiles.sh` | Exists (sourced) | ? | Custom scheduling profiles |

Total new code for swarm: **~120 lines of Bash**. That's the beauty of extending rather than rewriting.
