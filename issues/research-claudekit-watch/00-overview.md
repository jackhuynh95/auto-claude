# Research: ClaudeKit `ck watch` vs Auto-Claude Pipeline

**Date**: 2026-03-30
**Objective**: Evaluate how to merge CK watch patterns with auto-claude while preserving our unique strengths

---

## TL;DR

CK watch covers the **ship** workflow well (issue → plan → approval → code → PR). But it **lacks** E2E testing, Slack reporting, and our label-based routing. The merge strategy is: adopt CK's watcher daemon as the **orchestrator**, keep auto-claude's unique scripts as **plugins/phases** that CK calls.

---

## Feature Matrix: What Exists Where

| Capability | CK watch | Auto-Claude | Winner |
|---|---|---|---|
| Issue discovery & polling | Yes (issue-poller.ts) | Yes (looper.sh + gh labels) | Tie |
| Brainstorm → Issue creation | No | Yes (brainstorm-issue.sh + /brainstorm) | **Auto-Claude** |
| Slack reading → Task extraction | No | Yes (read-issue.sh + /slack-read) | **Auto-Claude** |
| Planning phase | Yes (claude-invoker.ts /plan) | Yes (ship-issue.sh step_2 /plan:fast) | Tie |
| Plan validation / approval gate | Yes (approval-checker.ts, comment polling) | Partial (--validate flag) | **CK watch** |
| Implementation phase | Yes (implementation-runner.ts) | Yes (ship-issue.sh step_3 /code:auto) | Tie |
| Debug → Fix → Test loop | No (only straight implementation) | Yes (fix-issue.sh 3-phase loop) | **Auto-Claude** |
| Worktree isolation | Yes (optional) | Yes (--worktree flag) | Tie |
| E2E testing (browser-based) | **No** | Yes (verify-issue.sh + agent-browser) | **Auto-Claude** |
| Frontend design review | **No** | Yes (--frontend-design flag) | **Auto-Claude** |
| Slack reporting (Bot API) | **No** | Yes (report-issue.sh + /slack-report) | **Auto-Claude** |
| Label-based pipeline routing | No (status field in .ck.json) | Yes (ready_for_dev → shipped → verified) | **Auto-Claude** |
| Smart issue type routing | No | Yes (BUG→fix, FEATURE→ship, DOCS→no-test) | **Auto-Claude** |
| Model routing per phase | No | Yes (opus=planning, sonnet=coding) | **Auto-Claude** |
| Fallback tools (codex/opencode) | No | Yes (--codex, --opencode flags) | **Auto-Claude** |
| Scheduling profiles | No (always-on daemon) | Yes (overnight/morning/daytime/continuous) | **Auto-Claude** |
| State persistence / crash recovery | Yes (.ck.json with TTL) | No (stateless, label-driven) | **CK watch** |
| Rate limiting awareness | Yes (per-hour caps) | No | **CK watch** |
| Process locking (no duplicate daemons) | Yes | Yes (.looper.lock) | Tie |
| Timeout enforcement (SIGTERM→SIGKILL) | Yes (per-phase) | No (relies on Claude CLI timeout) | **CK watch** |

---

## What CK Watch Does NOT Have (Our Moat)

### 1. E2E Testing via agent-browser
- `verify-issue.sh` runs real browser-based E2E tests (create-account, purchase-success)
- Checks `localhost:9000/health` before running
- Label transitions based on pass/fail: `ready_for_test → verified` or `→ ready_for_dev`
- CK has zero browser automation capability

### 2. Slack Integration (Both Directions)
- **Read**: `read-issue.sh` → `/slack-read` → task extraction → brainstorm pipeline
- **Write**: `report-issue.sh` → `/slack-report` → post summaries to `#medusa-agent-swarm`
- CK has no Slack awareness at all

### 3. Debug → Fix → Test Loop (3-phase)
- `fix-issue.sh` runs `/debug` (root cause) → `/fix` (apply) → `/test` (verify)
- Retries up to MAX_RETRIES with accumulated context
- Fallback to codex/opencode on exhaustion
- CK only has straight implementation (no debug analysis, no retry loop)

### 4. Smart Label-Based Routing
- Looper reads GitHub labels to determine pipeline stage
- Issue type detection: `[BUG]` → fix-issue.sh, `[FEATURE]` → ship-issue.sh
- Smart flag injection: `frontend` label → `--frontend-design`, `hard` label → `--hard`
- `[DOCS]/[CHORE]` → `--no-test` (skip unnecessary testing)

### 5. Model Routing
- Planning/reasoning phases: opus (default)
- Code execution: sonnet
- Slack reporting: haiku
- Per-flag override: `--model opus` forces all phases

### 6. Scheduling Profiles
- overnight: aggressive, every 2h, `--auto --hard --worktree`
- morning: summary + e2e verification
- daytime: light scan, e2e only
- continuous: full pipeline, every 1h

---

## What CK Watch Does Better

### 1. State Persistence (.ck.json)
- Tracks issue processing state across restarts
- TTL-based cleanup prevents stale entries
- Auto-claude is stateless — relies on labels (simpler but no crash recovery)

### 2. Approval Gates
- Explicit wait-for-approval phase before implementation
- Polls for maintainer comment to proceed
- Auto-claude has `--validate` but no blocking approval gate

### 3. Timeout Enforcement
- Per-phase timeout with SIGTERM → 5s → SIGKILL
- Auto-claude relies on Claude CLI's internal timeout (less control)

### 4. Rate Limiting
- Configurable per-hour API call caps
- Prevents GitHub API abuse in multi-repo setups

---

## Merge Strategy Options

See `01-merge-strategy.md` for detailed analysis.
