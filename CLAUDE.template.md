# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Auto-Claude is an autonomous issue processing pipeline. It scans GitHub issues by label and dispatches them to the right script automatically.

```
looper.sh → scans issues → routes by type → fix or ship → test → verify → close
```

## Role & Responsibilities

Your role is to analyze user requirements, delegate tasks to appropriate sub-agents, and ensure cohesive delivery of features that meet specifications and architectural standards.

## GitHub Integration

This project uses GitHub issues as the source of truth for features and bugs.

### Priority
- **Bugs before enhancements:** Always tackle issues labeled `bug` before those labeled `enhancement`

### Conventions
- "#N" or "issue #N" refers to GitHub issue number N
- Read issues with `gh issue view N` before planning
- Link commits with "closes #N" or "fixes #N"

### Issue Title Prefixes

These prefixes control how the looper routes issues:

| Prefix | Usage | Looper Action |
|--------|-------|---------------|
| `[BUG]` | Bug reports and defects | → `fix-issue.sh` (processed first) |
| `[FEATURE]` | New feature requests | → `ship-issue.sh` |
| `[ENHANCEMENT]` | Improvements to existing features | → `ship-issue.sh` |
| `[CHORE]` | Maintenance tasks, refactoring | → `ship-issue.sh` |
| `[DOCS]` | Documentation updates | → `ship-issue.sh` |
| `[WONTFIX]` | Never touch this | Skipped |
| `[WONTFEAT]` | Never touch this | Skipped |

### Pipeline Labels

Issues need these labels to enter the automated pipeline:

| Label | Meaning |
|-------|---------|
| `pipeline` | Issue is in the automated pipeline |
| `ready_for_dev` | Ready for Claude to fix/ship |
| `ready_for_test` | Fix shipped, needs e2e verification |
| `shipped` | PR created |
| `verified` | E2e passed, can close |
| `blocked` | Skip in pipeline |

To add an issue to the pipeline:
```bash
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev"
```

### Workflow
1. Read issue: `gh issue view N`
2. Parse requirements and acceptance criteria
3. Plan or implement based on issue content
4. Commit with reference to issue number

## Scripts

All scripts live at the project root. Key composable flags: `--auto`, `--worktree`, `--e2e`, `--no-test`, `--model <model>`.

| Script | Purpose |
|--------|---------|
| `looper.sh` | Pipeline commander — scans issues, routes to fix/ship |
| `fix-issue.sh` | Bug fix via `/fix` loop (default: sonnet, `--hard` uses opus) |
| `ship-issue.sh` | Feature ship via plan(opus) → code(sonnet) → PR |
| `ship-issue-no-test.sh` | Thin wrapper — `ship-issue.sh --no-test` |
| `ship-issues.sh` | Batch wrapper — passes all flags through |
| `setup-labels.sh` | Creates pipeline labels on GitHub (run once) |
| `research.sh` | Research a topic → create GitHub issue |
| `test-only.sh` | Run tests via Claude `/test` command |
| `looper-profiles.sh` | Custom scheduling profiles for looper |
| `install.sh` | Install auto-claude into another project |
| `release.sh` | Create GitHub release |

## Running the Pipeline

```bash
# One-time setup
./setup-labels.sh

# Manual scan
./looper.sh
./looper.sh --dry-run
./looper.sh --profile overnight

# Via /loop (Claude Code built-in, repeats on interval)
/loop 2h ./looper.sh --profile overnight
```

**IMPORTANT:** *MUST READ* and *MUST COMPLY* all *INSTRUCTIONS* in project `./CLAUDE.md`, especially *WORKFLOWS* section is *CRITICALLY IMPORTANT*, this rule is *MANDATORY. NON-NEGOTIABLE. NO EXCEPTIONS. MUST REMEMBER AT ALL TIMES!!!*
