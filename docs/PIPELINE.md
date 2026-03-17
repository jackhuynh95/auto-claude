# Pipeline Guide

Full reference for the auto-claude autonomous issue pipeline.

---

## How It Works

```
Slack #medusa-agent-swarm (daily read)
  └─→ brainstorm_issue.sh (auto-create issue from task)
        └─→ /brainstorm "idea"
              └─→ discussion & research
                    └─→ "Create GitHub Issue?" → /issue
                          └─→ gh issue create --label "pipeline,ready_for_dev,<type>"
                                └─→ looper.sh scans on interval (/loop)
                                      ├─→ ready_for_dev:
                                      │     ├─→ [BUG]              → fix-issue.sh
                                      │     ├─→ [FEATURE/ENHANCE]  → ship-issue.sh
                                      │     └─→ [WONTFIX/WONTFEAT] → skipped
                                      │           └─→ on success → ready_for_test
                                      └─→ ready_for_test:
                                            └─→ verify-issue.sh (e2e)
                                                  ├─→ pass → verified → closed
                                                  └─→ fail → ready_for_dev (re-queued)
                                                        └─→ report-issue.sh → Slack #medusa-agent-swarm
```

You can also skip brainstorming and create issues directly:

```bash
/issue "Add dark mode toggle"           # interactive — asks type, labels
/issue plans/reports/brainstorm-*.md    # from brainstorm output
```

**Bugs are always processed before features.**

---

## Pipeline Stages (Labels as Kanban)

Run `./setup-labels.sh` once to create all labels on GitHub.

### Stage Labels

| Label | Color | Meaning |
|-------|-------|---------|
| `pipeline` | light blue | Opt-in gate — looper only processes issues with this label |
| `ready_for_dev` | green | Queued for Claude to fix/ship |
| `ready_for_test` | yellow | Fix shipped, awaiting e2e verification |
| `shipped` | purple | PR created |
| `verified` | blue | E2e passed, will be closed |
| `blocked` | red | Skipped by looper |

### Type Labels (affect looper behavior)

| Label | Color | Looper auto-adds |
|-------|-------|-----------------|
| `frontend` | orange | `--frontend-design` — runs UI review after fix |
| `hard` | dark red | `--hard` — uses Opus model for complex issues |

### Flag Labels (informational)

| Label | Color | Meaning |
|-------|-------|---------|
| `needs_design_review` | yellow | Shown in summary — you review manually |

---

## Adding Issues to the Pipeline

### Via `/issue` command (recommended)

```bash
/issue "Add dark mode toggle"           # interactive — asks type, labels, drafts body
/issue plans/reports/brainstorm-*.md    # from brainstorm output
```

The `/issue` command auto-adds `pipeline` + `ready_for_dev` labels and creates a structured issue body that `ship-issue.sh` / `fix-issue.sh` can work with autonomously.

### Via `gh` CLI (manual)

```bash
# Minimal — standard bug or feature
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev"

# Frontend issue — looper auto-runs design review
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev" --add-label "frontend"

# Complex bug — looper uses Opus
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev" --add-label "hard"

# Batch triage
for num in 42 43 44 45; do
  gh issue edit $num --add-label "pipeline" --add-label "ready_for_dev"
done
```

**Title prefixes also control behavior** — no extra labels needed:

| Title Prefix | Routes to | Extra flag |
|-------------|-----------|------------|
| `[BUG] ...` | `fix-issue.sh` | — |
| `[FEATURE] ...` | `ship-issue.sh` | — |
| `[ENHANCEMENT] ...` | `ship-issue.sh` | — |
| `[CHORE] ...` | `ship-issue.sh` | `--no-test` (auto) |
| `[DOCS] ...` | `ship-issue.sh` | `--no-test` (auto) |
| `[WONTFIX] ...` | skipped | — |
| `[WONTFEAT] ...` | skipped | — |

---

## Running the Looper

### Manual

```bash
./looper.sh                          # full scan (all stages)
./looper.sh --dry-run                # preview — shows what would run
./looper.sh --label ready_for_dev   # single stage only
./looper.sh --limit 3               # cap at 3 issues
```

### Via `/loop` (Claude Code built-in — repeats on interval)

```bash
/loop 2h ./looper.sh --profile overnight
/loop 4h ./looper.sh --profile daytime
/loop 1h ./looper.sh --profile continuous
```

### Scheduling Profiles

| Profile | When | Behavior | Limit |
|---------|------|----------|-------|
| `overnight` | 10pm–6am, every 2h | `--auto --hard` on `ready_for_dev` | 5 |
| `morning` | Once at 7am | Summary + e2e verify `ready_for_test` | 10 |
| `daytime` | 8am–8pm, every 4h | e2e only on `ready_for_test` | 3 |
| `continuous` | 24/7, every 1h | Full pipeline scan | 3 |

Custom profiles: add `profile_<name>()` functions to `looper-profiles.sh`.

---

## Composable Flags

All flags work on both `fix-issue.sh` and `ship-issue.sh`.

| Flag | Description |
|------|-------------|
| `--auto` | YOLO mode — skip permission prompts |
| `--hard` | Skip `/debug`, use `/fix:hard` + Opus directly (complex bugs) |
| `--e2e` | Run e2e after fix/ship — gates PR on pass |
| `--e2e-only` | Delegates to `verify-issue.sh` (for `ready_for_test` stage) |
| `--frontend-design` | UI review after fix/ship — report only, doesn't gate PR |
| `--frontend-design-only` | UI review only |
| `--validate` | Run `/plan:validate` after planning — gates implementation |
| `--no-test` | Skip tests — for docs, configs, trivial changes |
| `--model <model>` | Force model override for all phases |
| `--codex` / `--opencode` | Fallback tool if Claude fails (`fix-issue.sh` only) |

### Example Combinations

```bash
# Standard bug fix (sonnet)
./fix-issue.sh 42 --auto

# Complex bug (opus)
./fix-issue.sh 42 --auto --hard

# Bug fix with e2e verification
./fix-issue.sh 42 --auto --e2e

# Feature with UI
./ship-issue.sh 42 --auto --frontend-design

# Docs update (no tests)
./ship-issue.sh 42 --auto --no-test

# Batch multiple issues
./ship-issues.sh "39,41,42" --auto
```

---

## Fix Workflow

`fix-issue.sh` runs a 3-phase cycle, retrying up to `FIX_MAX_RETRIES` (default 3):

```
Standard (default):     /debug (opus) → /fix (sonnet) → /test → retry on fail
Hard mode (--hard):     /fix:hard (opus) → /test → retry on fail
```

- **`/debug`** — Read-only root cause analysis. Output feeds into `/fix` as context.
- **`/fix`** — Intelligent routing (`/fix:fast`, `/fix:hard`, `/fix:types`, etc. based on issue).
- **`/test`** — Runs tests to verify fix. On failure, test output feeds back into next `/debug` cycle.

If all retries exhausted, falls back to `--codex` or `--opencode` if specified.

---

## Model Routing

| Task | Model | Why |
|------|-------|-----|
| `/plan`, `/debug`, `/brainstorm`, `/frontend-design` | Opus | Reasoning |
| `/code`, `/fix`, `/cook`, `e2e-test` | Sonnet | Execution |
| `--hard` fix | Opus | Complex bug analysis |
| `--model <override>` | Your choice | All phases |

Saves ~60–70% tokens vs running everything on Opus.

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `looper.sh` | Commander — scans labels, dispatches to fix/ship/verify |
| `fix-issue.sh` | Bug fix: `/debug` → `/fix` → `/test` cycle → PR (`--hard` skips debug) |
| `ship-issue.sh` | Feature ship: plan(opus) → code(sonnet) → PR |
| `verify-issue.sh` | E2E verify: checkout PR branch → e2e test → label transition |
| `ship-issue-no-test.sh` | Thin wrapper: `ship-issue.sh --no-test` |
| `ship-issues.sh` | Batch: runs `ship-issue.sh` for multiple issues |
| `setup-labels.sh` | Create all pipeline labels on GitHub (run once) |
| `looper-profiles.sh` | Custom scheduling profiles |
| `test-only.sh` | Run Claude `/test` command standalone |
| `brainstorm_issue.sh` | Read Slack tasks → brainstorm → create GitHub issue (planned) |
| `report-issue.sh` | Post-fix/ship Slack reporting — wraps `slack-report` (planned) |
| `/issue` | Create pipeline-ready GitHub issue (interactive or from brainstorm) |
| `/brainstorm` | Ideation → optionally creates issue via `/issue` |
| `research.sh` | Research topic → create GitHub issue |

---

## Slack Integration (Agent Swarm)

Channel: `#medusa-agent-swarm`

| Script | Purpose | Status |
|--------|---------|--------|
| `brainstorm_issue.sh` | Read Slack tasks → `/brainstorm` → `/issue` | Planned |
| `report-issue.sh` | Post-fix/ship reporting → Slack via `slack-report` | Planned |
| `/uncle-report` | Daily summary for Thierry on log channel | Active |

### Full Loop

```
Slack read → brainstorm_issue.sh → /issue → looper.sh → fix/ship → report-issue.sh → Slack post
```

Morning routine: agent reads `#medusa-agent-swarm` for daily tasks, processes them through the pipeline, reports results back.

---

## Requirements

- `claude` — Claude Code CLI, authenticated
- `gh` — GitHub CLI, authenticated (`gh auth login`)
- `jq` — JSON processor (`brew install jq`)
- `git` — with push access to repo
