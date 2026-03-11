# Auto-Claude

Autonomous issue processing pipeline powered by Claude Code CLI.

## How It Works

```
GitHub Issues (labeled "pipeline" + "ready_for_dev")
  └─→ looper.sh scans by label
        ├─→ [BUG]              → fix-issue.sh (sonnet, opus for --hard)
        ├─→ [FEATURE/ENHANCE]  → ship-issue.sh (sonnet)
        ├─→ [WONTFIX/WONTFEAT] → skipped
        └─→ success → label "ready_for_test"
              └─→ e2e pass → "verified" → closed
              └─→ e2e fail → "ready_for_dev" (re-queue)
```

**Bugs are always processed before features.**

## Quick Start

```bash
# 1. Setup pipeline labels on GitHub (once)
./setup-labels.sh

# 2. Label issues for the pipeline
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev"

# 3. Run the looper
./looper.sh                          # scan all
./looper.sh --dry-run                # preview only
./looper.sh --profile overnight      # scheduling profile

# 4. Or via /loop (Claude Code built-in, runs on interval)
/loop 2h ./looper.sh --profile overnight
```

## Scripts

| Script | What it does |
|--------|-------------|
| `looper.sh` | Pipeline commander — scans issues by label, routes to fix/ship |
| `fix-issue.sh` | Bug fix: `/fix` loop → build check → retry → PR |
| `ship-issue.sh` | Feature ship: plan → code → PR |
| `ship-issues.sh` | Batch: runs ship-issue.sh for multiple issues |
| `research.sh` | Research a topic → create GitHub issue |
| `setup-labels.sh` | Create pipeline labels on GitHub |
| `looper-profiles.sh` | Custom scheduling profiles |
| `ship-issue-no-test.sh` | Ship without tests |
| `test-only.sh` | Run `/test` only |

## Composable Flags

All flags work on both `fix-issue.sh` and `ship-issue.sh`. `ship-issues.sh` passes all flags through.

| Flag | Description |
|------|-------------|
| `--auto` | YOLO mode (skip permissions) |
| `--worktree` | Isolated git worktree (`/tmp/fix-issue-<num>`) |
| `--e2e` | Run e2e after fix/ship, gates PR on pass |
| `--e2e-only` | E2e test only, no fix/ship |
| `--frontend-design` | UI review after fix/ship (report only, user-controlled) |
| `--frontend-design-only` | UI review only |
| `--model <model>` | Force model (default: sonnet, `--hard` uses opus) |
| `--hard` | `/fix:hard` + opus (fix-issue.sh only) |
| `--codex` / `--opencode` | Fallback tools (fix-issue.sh only) |

### Examples

```bash
# Bug fix
./fix-issue.sh 42                              # basic fix (sonnet)
./fix-issue.sh 42 --hard                       # complex bug (opus)
./fix-issue.sh 42 --auto --worktree --e2e      # full pipeline

# Feature ship
./ship-issue.sh 42 --auto                      # plan → code → PR
./ship-issue.sh 42 --auto --worktree --e2e     # isolated + verified

# Batch
./ship-issues.sh "39,41,42" --auto --worktree

# E2e verification only
./fix-issue.sh 42 --e2e-only
```

## Pipeline Labels

Labels = Kanban columns. Created by `./setup-labels.sh`.

| Label | Color | Role |
|-------|-------|------|
| `pipeline` | light blue | Issue is in the automated pipeline |
| `ready_for_dev` | green | Ready for Claude to fix/ship |
| `ready_for_test` | yellow | Fix shipped, needs e2e verification |
| `shipped` | purple | PR created |
| `verified` | blue | E2e passed, can close |
| `blocked` | red | Skip in pipeline |
| `needs_design_review` | yellow | Needs manual UI review |

## Issue Type Routing

From `CLAUDE.md` conventions:

| Title Prefix | Script | Priority |
|-------------|--------|----------|
| `[BUG]` | `fix-issue.sh` | First |
| `[FEATURE]` | `ship-issue.sh` | After bugs |
| `[ENHANCEMENT]` | `ship-issue.sh` | After bugs |
| `[CHORE]` / `[DOCS]` | `ship-issue.sh` | After bugs |
| `[WONTFIX]` / `[WONTFEAT]` | Skipped | — |

## Scheduling Profiles

```bash
./looper.sh --profile overnight    # aggressive: --auto --hard --worktree, limit 5
./looper.sh --profile morning      # summary + e2e verify, limit 10
./looper.sh --profile daytime      # e2e only, limit 3
./looper.sh --profile continuous   # full scan, limit 3
```

Custom profiles: edit `looper-profiles.sh`.

## Model Routing

| Task | Model | Why |
|------|-------|-----|
| Standard fix/ship | Sonnet | Fast, cheap |
| `--hard` fix | Opus | Deep reasoning |
| `--model opus` | Opus | Explicit override |

Saves ~60-70% tokens on execution-heavy tasks.

## Requirements

- `claude` (Claude Code CLI)
- `gh` (GitHub CLI)
- `jq` (JSON processor)
- `git` with push access
