# ClaudeKit CLI `ck watch` Command Research Report

**Date**: 2026-03-30
**Repo**: mrgoonie/claudekit-cli
**Focus**: End-to-end watch daemon architecture and Claude CLI integration patterns

---

## Executive Summary

`ck watch` is a **long-running GitHub issue daemon** that automates issue analysis → planning → approval → implementation → PR creation. Built in TypeScript/Bun, it demonstrates a sophisticated multi-phase orchestration model with robust state persistence, rate limiting, and optional worktree isolation. The architecture offers valuable patterns for auto-claude's looper/fix-issue pipeline.

---

## How `ck watch` Works

### Phase-Based Lifecycle

Issues progress through 10 distinct statuses:
```
new → brainstorming → clarifying → planning → awaiting_approval
→ implementing → completed
```

Each phase has dedicated modules (20 total in `src/commands/watch/phases/`):
- **Discovery**: `issue-poller.ts`, `repo-scanner.ts`
- **Analysis**: `claude-invoker.ts` (brainstorm + plan)
- **Approval**: `approval-checker.ts`, `comment-poller.ts`
- **Implementation**: `implementation-runner.ts` + Git helpers
- **State**: `state-manager.ts`, `state-cleanup.ts`, `plan-lifecycle.ts`

### Configuration & Persistence

- State stored in `.ck.json` with TTL-based cleanup
- Rate limiting tracked across restarts (configurable per-hour caps)
- Process locking prevents duplicate daemons
- Graceful shutdown with atomic saves

---

## Claude CLI Child Process Spawning

**Key Pattern** — The `implementation-runner.ts` spawns Claude as a subprocess:

```typescript
const child = spawn("claude", args, {
  cwd,                              // Working directory
  stdio: ["pipe", "pipe", "pipe"],  // stdin/stdout/stderr piped
  detached: false
});

// Passes prompt via stdin:
// "Complete implementation, stage changes, commit with format X, don't push"
```

**Tool Access**: Claude receives `"Read,Grep,Glob,Bash,Write,Edit"` capabilities.

**Timeout Management**:
- Timer enforces specified timeout
- SIGTERM first, then SIGKILL after 5 seconds
- Non-zero exit codes trigger rejection
- Stderr buffered (truncated to 500 chars max)

**Key Insight**: The runner ensures Claude **commits changes locally** before the runner handles Git push/PR externally. Clear separation of concerns.

---

## Worktree Isolation Mode

Two execution paths in `runImplementation()`:

1. **Worktree Mode** (isolated):
   - Creates temp worktree
   - Runs Claude inside isolated branch
   - Pushes and creates PR externally
   - Clean separation of issue implementations

2. **Standard Mode**:
   - Saves current branch state
   - Checks out new branch
   - Invokes Claude
   - Restores original state

---

## Relationship to `/ck:cook` Skill Pattern

ClaudeKit's **`/ck:cook`** maps directly to `ck watch` phases:

- **Brainstorm Phase**: Claude /brainstorm (opus, max effort)
- **Planning Phase**: Claude /plan (generates implementation strategy)
- **Implementation Phase**: Claude child process with isolated tools
- **Approval**: Manual user confirmation (daemon waits)
- **PR Creation**: Atomic external operation after Claude completes

This mirrors auto-claude's conceptual pipeline but with explicit daemon orchestration instead of shell script sequencing.

---

## Architecture Strengths & Learnable Patterns

| Pattern | Value for auto-claude |
|---------|----------------------|
| **Modular Phase Files** (20 dedicated modules) | Better than monolithic shell script; enables testability |
| **Process Isolation** (Claude as subprocess) | Safer than in-process execution; clean error handling |
| **State Persistence** (.ck.json) | Crash recovery; resume from last known state |
| **Rate Limiting Awareness** | GitHub API protection; multi-repo safety |
| **Explicit Approval Gate** | Prevents runaway automation; user control |
| **Worktree Isolation Option** | Clean parallel issue handling |

---

## Comparison with auto-claude's looper

| Aspect | ck watch | auto-claude looper |
|--------|----------|-------------------|
| **Execution Model** | Daemon (always running) | Periodic cron (looper.sh on interval) |
| **Process Spawning** | Node.js child process | Bash shell command |
| **State Persistence** | .ck.json with TTL | Label-based (GitHub issue labels) |
| **Approval** | Explicit wait gate | User PR review (implicit) |
| **Isolation** | Optional worktree | Bash env isolation (proposed --worktree) |

ck watch is **more sophisticated** but auto-claude's label-based approach (Thierry's suggestion) is simpler operationally.

---

## Key Takeaways for auto-claude

1. **Child Process Pattern**: Use `spawn("claude", ...)` with piped stdio for safer isolation than inline execution
2. **Phase Decomposition**: Break down fix-issue.sh into dedicated phase modules (easier testing/debugging)
3. **Explicit Approval Gates**: Consider approval/review gates in daemon mode (prevent uncontrolled PR spam)
4. **Worktree as First-Class**: Build `--worktree` flag as a parallel execution mode (ClaudeKit validates this approach)
5. **State Persistence**: Track issue processing in state file (complement label-based routing for recovery)
6. **Timeout Enforcement**: SIGTERM + SIGKILL pattern handles runaway processes cleanly
7. **Tool Gating**: Limit Claude's tool access per phase (e.g., no Write in approval phase)

---

## Unresolved Questions

- How does ck watch handle multi-repo rate limiting? Does it deduplicate API calls across repos?
- What's the actual `.ck.json` schema? (structure, version field, TTL format)
- Does approval polling block or async-check? How frequently?
- How does worktree cleanup handle dangling branches on crash?
