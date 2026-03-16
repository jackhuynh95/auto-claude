# Research 00: Swarm Direction — Where This Repo Actually Stands

## Context

This repo already **is** a working single-agent pipeline. The question isn't "should we build a loop first?" — we already have one. The real question is: **what's the cheapest path from the current 4-script pipeline to a multi-agent swarm that's worth running overnight unsupervised?**

## What We Have Today (Not Theory — Actual Code)

| Script | Role | Model Routing | Safety |
|---|---|---|---|
| `looper.sh` | Commander. Scans labels, dispatches scripts. Lock file prevents concurrent runs. | Profile-based (overnight/morning/daytime/continuous) | Lock file, iteration limit, dry-run mode |
| `fix-issue.sh` | Bug fixer. 3-phase: `/debug` → `/fix` → `/test` with retry. | Sonnet for fixes, Opus for reasoning/hard bugs | Max retries, build validation, fallback to Codex/OpenCode |
| `ship-issue.sh` | Feature shipper. `/plan` → `/code` → commit → PR. | Opus for planning, Sonnet for coding | Plan validation gate, stash dirty tree, label transitions |
| `verify-issue.sh` | E2E verifier. Checks PR branch, runs browser tests. | Sonnet (execution task) | Health check gate, false-positive detection |

**Key insight**: The foundation GPT 5.4 said to build already exists. The circuit breaker, exit gates, retry logic, model routing — they're live. What's missing is **parallelism** and **cross-worker coordination**.

## The Two Gaps That Matter

### Gap 1: Serial Bottleneck
`looper.sh` processes issues one-by-one inside `process_issues_by_label()`. A 5-issue overnight run with `fix-issue.sh` (each taking 10-20 min) means 1-2 hours sequential. With 3 parallel workers, that's 25-40 min.

### Gap 2: No Worker Isolation
`fix-issue.sh` uses `--worktree` for git isolation, but there's no process isolation. Two concurrent `fix-issue.sh` instances would fight over:
- The same `claude` CLI session
- Git checkout state (even with worktrees, `looper.sh` does `git checkout main` between issues)
- The lock file in `looper.sh`

## Concrete Recommendation

**Don't rewrite. Extend.** The pipeline is already label-driven and script-composable. The swarm layer should be:

1. **`spawn-worker.sh`** — wraps `fix-issue.sh`/`ship-issue.sh` in a tmux pane with its own worktree, log file, and process ID. Returns immediately.
2. **`swarm-commander.sh`** — replaces the `process_issues_by_label` loop in `looper.sh`. Spawns N workers, polls for completion, collects exit codes.
3. **Worker result protocol** — each worker writes a JSON status file (`logs/worker-{issue}-status.json`) with `{issue, status, pr_url, duration, exit_code}`. Commander reads these.

The existing scripts (`fix-issue.sh`, `ship-issue.sh`, `verify-issue.sh`) don't change at all. They already accept flags and produce logs. They just need to run inside a tmux pane with a dedicated worktree.

## What GPT 5.4 Got Right vs Wrong

| Claim | Verdict |
|---|---|
| "Build loop stability first, then swarm" | Correct direction, but the loop is already stable. We're past this phase. |
| "Model diversity only helps once orchestration is dependable" | Already implemented — model routing exists per Issue 07. |
| "`ralph-claude-code` is the stronger v1 foundation" | True at inception. But this repo has diverged significantly with label routing, smart flags, and profile-based scheduling. |
| "Add model routing second" | Already done. Next step is parallelism, not routing. |

## Decision Framework

Before building swarm features, answer:

1. **How many issues per night?** If <5, serial is fine. If 10+, parallelism pays off.
2. **Do we trust `--auto` on parallel workers?** If not, swarm is just "serial but in tmux panes" — still useful for visibility but not speed.
3. **What's the blast radius of a bad parallel fix?** Two workers can't touch the same files (worktree isolation handles this), but they can create conflicting PRs. Acceptable?
