# Autonomous Claude

End-to-end automation: Research → GitHub Issue → Plan → Code → PR

## Quick Install

**Add to any project:**
```bash
cd /path/to/your-project
curl -fsSL https://raw.githubusercontent.com/jackhuynh95/auto-claude/main/install.sh | bash
```

This downloads scripts to `.auto-claude/` and adds it to `.gitignore`.

**Usage:**
```bash
.auto-claude/ship-issue.sh 42        # Ship issue #42
.auto-claude/fix-issue.sh 42         # Fix issue #42
.auto-claude/fix-issue.sh 42 --hard  # Complex fix (/fix:hard)
.auto-claude/ship-issues.sh "1,2,3"  # Batch ship
```

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    .auto-claude/                           │
├────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐      ┌──────────────────┐           │
│  │   Bash Scripts   │      │   .claude/commands │          │
│  │   (.sh files)    │      │   (slash commands) │          │
│  ├──────────────────┤      ├──────────────────┤           │
│  │ ✅ TRUE AUTONOMOUS│      │ ⚡ INTERACTIVE    │           │
│  │ • Runs headless  │      │ • Requires Claude │           │
│  │ • CI/CD ready    │      │ • /test, /code    │           │
│  │ • No human needed│      │ • Human-in-loop   │           │
│  └──────────────────┘      └──────────────────┘           │
└────────────────────────────────────────────────────────────┘
```

---

## Bash Scripts

**For CI/CD, cron jobs, and headless execution.**

| Script | Usage | Description |
|--------|-------|-------------|
| `research.sh` | `./research.sh "topic"` | Research → create issue |
| `research.sh` | `./research.sh "topic" --auto` | Quick issue (YOLO) |
| `ship-issue.sh` | `./ship-issue.sh 42` | Full: plan → code → PR (sonnet) |
| `ship-issue.sh` | `./ship-issue.sh 42 --auto --worktree --e2e` | YOLO + worktree + e2e verify |
| `ship-issues.sh` | `./ship-issues.sh "39,41,42"` | **Batch:** multiple issues sequentially |
| `ship-issues.sh` | `./ship-issues.sh "39,41" --auto --worktree` | Batch with all flags passed through |
| `fix-issue.sh` | `./fix-issue.sh 42` | **Bug fix:** `/fix` loop → PR |
| `fix-issue.sh` | `./fix-issue.sh 42 --hard` | `/fix:hard` (opus) for complex issues |
| `fix-issue.sh` | `./fix-issue.sh 42 --auto --worktree --e2e` | Isolated worktree + e2e verify |
| `looper.sh` | `bash .claude/scripts/looper.sh` | **Pipeline:** scan issues by label → dispatch |
| `looper.sh` | `bash .claude/scripts/looper.sh --profile overnight` | With scheduling profile |
| `setup-labels.sh` | `bash .claude/scripts/setup-labels.sh` | Create pipeline labels on GitHub |
| `ship-issue-no-test.sh` | `./ship-issue-no-test.sh 42` | Skip tests (docs/config) |
| `test-only.sh` | `./test-only.sh` | Run `/test` via Claude CLI |
| `test-only.sh` | `./test-only.sh --fix` | YOLO mode |
| `test-only.sh` | `./test-only.sh "args"` | Pass args to `/test` |

**Scripts that delegate to Claude CLI commands:**
- `test-only.sh` → `/test`
- `fix-issue.sh` → `/fix` or `/fix:hard`

**Scripts with full implementation:**
- `research.sh` - hypothesis-driven research → `research/*.md` file → structured GitHub issue
- `ship-issue.sh` - 6-step workflow (branch → plan → code → post reports → commit → PR)
- `ship-issues.sh` - batch wrapper: process multiple issues sequentially with main reset between each
- `fix-issue.sh` - `/fix` loop (--hard for `/fix:hard`) + Codex/OpenCode fallback
- `ship-issue-no-test.sh` - same as ship-issue but uses `/code:no-test`

---

## ship-issue.sh Features

```bash
./ship-issue.sh 42                              # plan → code → PR (sonnet)
./ship-issue.sh 42 --auto                       # YOLO mode
./ship-issue.sh 42 --auto --worktree            # isolated git worktree
./ship-issue.sh 42 --auto --e2e                 # ship then e2e verify
./ship-issue.sh 42 --e2e-only                   # e2e test only (no ship)
./ship-issue.sh 42 --frontend-design            # ship then UI review
./ship-issue.sh 42 --frontend-design-only       # UI review only
./ship-issue.sh 42 --model opus                 # force opus model
```

**Composable Flags:**

| Flag | Description |
|------|-------------|
| `--auto` | YOLO mode (skip permissions) |
| `--worktree` | Run in isolated git worktree at `/tmp/ship-issue-<num>` |
| `--e2e` | Run e2e-test after implementation, gates PR creation |
| `--e2e-only` | Skip ship, just run e2e (for `ready_for_test` stage) |
| `--frontend-design` | Run UI design review after ship (report only) |
| `--frontend-design-only` | Standalone UI review (no ship) |
| `--model <model>` | Force specific model (default: sonnet) |

**Workflow:**
1. Branch setup from issue title (or worktree)
2. Planning via Claude CLI
3. Implementation via Claude CLI
4. *(optional)* E2E verification — `--e2e` gates PR on pass
5. *(optional)* Frontend design review — `--frontend-design` reports only
6. **Post reports** - finds `apps/**/*report*.md`, posts to GitHub issue, deletes files
7. Commit changes
8. Create PR + label transition (`ready_for_dev` → `ready_for_test`)
9. Worktree cleanup (if `--worktree`)

**Optimizations:**
- Single GitHub API call (cached with `jq`)
- `shipped` label auto-created if missing (purple #7057ff)
- Report files posted then cleaned up (not in final commit)

**Requirements:**
- `gh` (GitHub CLI)
- `jq` (JSON processor)
- `claude` (Claude CLI)
- [ClaudeKit Engineer](https://github.com/claudekit) (paid) - provides `/plan`, `/code`, `/fix`, `/test` slash commands

---

## ship-issues.sh (Batch Mode)

**Process multiple issues sequentially with clean isolation.**

```bash
./ship-issues.sh "39,41,42" --auto
./ship-issues.sh "39,41,42" --auto --worktree --e2e   # all flags pass through
```

**Flow:**
1. Parse comma-separated issue numbers
2. For each issue:
   - `git checkout main && git pull` (clean slate)
   - Run `./ship-issue.sh <issue> [flags...]` (all flags pass through)
   - Track success/failure
3. Final reset to main
4. Print summary

**Output:**
```
Total Issues:  3
Succeeded:     2 - [39 41]
Failed:        1 - [42]
```

**Features:**
- Continues processing even if one issue fails
- Each issue gets fresh main branch (no conflicts)
- Batch log: `logs/ship-batch-*.log`

---

## fix-issue.sh (Bug Fix Workflow)

**For bug issues - uses `/fix` loop with composable flags.**

```bash
./fix-issue.sh 42                              # /fix loop (sonnet)
./fix-issue.sh 42 --auto                       # YOLO mode
./fix-issue.sh 42 --hard                       # /fix:hard (opus)
./fix-issue.sh 42 --auto --worktree            # isolated git worktree
./fix-issue.sh 42 --auto --e2e                 # fix then e2e verify
./fix-issue.sh 42 --e2e-only                   # e2e test only (no fix)
./fix-issue.sh 42 --frontend-design            # fix then UI review
./fix-issue.sh 42 --frontend-design-only       # UI review only
./fix-issue.sh 42 --model opus                 # force model
./fix-issue.sh 42 --auto --codex               # Codex fallback
./fix-issue.sh 42 --auto --opencode            # OpenCode fallback
```

**Composable Flags:**

| Flag | Description |
|------|-------------|
| `--auto` | YOLO mode (skip permissions) |
| `--hard` | Use `/fix:hard` + opus model |
| `--worktree` | Run fix in isolated git worktree at `/tmp/fix-issue-<num>` |
| `--e2e` | Run e2e-test after fix, gates PR creation |
| `--e2e-only` | Skip fix, just run e2e (for `ready_for_test` stage) |
| `--frontend-design` | Run UI design review after fix (report only) |
| `--frontend-design-only` | Standalone UI review (no fix) |
| `--model <model>` | Force specific model (default: sonnet, `--hard` uses opus) |
| `--codex` | Codex (GPT-5.2-high) fallback after max retries |
| `--opencode` | OpenCode fallback after max retries |

**Workflow:**
1. Branch setup (`fix/issue-{num}-{slug}`)
2. Fix loop — runs `/fix` or `/fix:hard`, builds, retries (max 3)
3. *(optional)* E2E verification — `--e2e` gates PR on pass
4. *(optional)* Frontend design review — `--frontend-design` reports only
5. Commit + create PR
6. Label transition (`ready_for_dev` → `ready_for_test`)
7. Worktree cleanup (if `--worktree`)

**Model Routing:**
- Default: `--model sonnet` (fast, cheap)
- `--hard`: opus (deep reasoning)
- `--model <name>`: explicit override

**Environment variables:**
- `FIX_AUTO=true` - same as `--auto` flag
- `FIX_MAX_RETRIES=3` - max fix attempts before fallback

---

## Looper Pipeline (Automated Issue Processing)

**24/7 unattended pipeline: scan GitHub issues by label → dispatch fix → test → verify → close.**

Labels act as Kanban columns (no separate board needed):

```
ready_for_dev → ready_for_test → verified → closed
```

### Setup

```bash
# Create pipeline labels on GitHub (run once)
bash .claude/scripts/setup-labels.sh

# Label an issue for the pipeline
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev"
```

### Usage

```bash
# Manual run (from terminal)
bash .claude/scripts/looper.sh
bash .claude/scripts/looper.sh --label ready_for_dev   # single label
bash .claude/scripts/looper.sh --dry-run               # scan only
bash .claude/scripts/looper.sh --limit 3               # cap per run
bash .claude/scripts/looper.sh --profile overnight     # scheduling profile
```

**Via `/loop` (Claude Code built-in)** — runs a prompt on a recurring interval:

```
# Inside Claude Code interactive session:
/loop 2h bash .claude/scripts/looper.sh
/loop 2h bash .claude/scripts/looper.sh --profile overnight
/loop 4h bash .claude/scripts/looper.sh --profile daytime
/loop 10m bash .claude/scripts/looper.sh --dry-run      # monitor only
```

`/loop <interval> <prompt>` — Claude executes the prompt every `<interval>` (default 10m).
The prompt is run through Claude, which uses the Bash tool to execute the script.

### Scheduling Profiles

| Profile | Behavior |
|---------|----------|
| `overnight` | Every 2h, `ready_for_dev` only, `--auto --hard --worktree`, limit 5 |
| `morning` | Summary report + `ready_for_test` e2e verification, limit 10 |
| `daytime` | `ready_for_test` e2e only, limit 3 |
| `continuous` | All labels, `--auto --worktree`, limit 3 |

Custom profiles: edit `.claude/scripts/looper-profiles.sh`.

### Pipeline Flow

```
Issue labeled "pipeline" + "ready_for_dev"
  └─→ looper.sh picks it up
        └─→ fix-issue.sh <num> --auto --worktree
              └─→ success: label → "ready_for_test"

Next scan: "ready_for_test"
  └─→ fix-issue.sh <num> --e2e-only
        ├─→ pass:  label → "verified", close issue
        └─→ fail:  label → "ready_for_dev" (re-queue)
```

---

## CI/CD Example

```yaml
# .github/workflows/auto-ship.yml
on:
  issues:
    types: [labeled]

jobs:
  ship:
    if: github.event.label.name == 'auto-ship'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./.auto-claude/ship-issue.sh ${{ github.event.issue.number }} --auto
```

---

## When to Use What

| Scenario | Use | Why |
|----------|-----|-----|
| CI/CD pipeline | `.sh` scripts | No Claude session |
| GitHub Actions | `.sh` scripts | Automated, headless |
| Cron job | `.sh` scripts | Scheduled |
| Local with Claude | `/test`, `/code` | Interactive |

---

## File Reference

```
.auto-claude/
├── README.md             # This file
├── research.sh           # Full impl: research → research/*.md → GitHub issue
├── ship-issue.sh         # Full impl: plan → code → reports → PR (single issue)
├── ship-issues.sh        # Batch: multiple issues sequentially (wraps ship-issue.sh)
├── fix-issue.sh          # Bug fix: plan → code → fix loop → fallback → PR
├── ship-issue-no-test.sh # Full impl: plan → code → PR (no test)
├── test-only.sh          # Delegates to /test
└── prompts/
    └── research.txt      # Research prompt template (hypothesis-driven methodology)
```

---

## research.sh Details

**Workflow:**
1. Claude researches topic using hypothesis-driven methodology
2. Creates detailed research file at `research/{slug}-{date}.md`
3. Extracts structured issue body from Claude output (between markers)
4. Creates GitHub issue with full context (Overview, Scope, Decision, Checklist, Risks)

**Research Methodology (built into prompt):**
- Form competing hypotheses, track confidence levels
- Evaluate 2-3 approaches with pros/cons
- Self-critique: "What am I missing?"
- Document dead ends and rejected paths

**Output Format:**
- Research file: `research/{topic-slug}-{YYYY-MM-DD}.md`
- GitHub issue: Structured body matching issue template (see issue #22 for example)

**Fallback:** If Claude doesn't output markers, uses basic template

---

## Philosophy

> **"Claude can't run itself through .md files. The bash scripts are the true autonomous implementation."**

- `.sh` = Machine executes (true autonomy)
- `.md` = Reference docs for interactive sessions

---

## Reference

- [ClaudeKit Workflow](./claudekit-workflow.md) - Recommended workflow for fixing issues (Plan → Code → Fix → Codex fallback)
- Based on: "Engineering Report: Autonomous Orchestration of Claude Code CLI"
