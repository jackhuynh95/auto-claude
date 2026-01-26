# Autonomous Claude

End-to-end automation: Research → GitHub Issue → Plan → Code → PR

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
| `ship-issue.sh` | `./ship-issue.sh 42` | Full: plan → code → test → PR |
| `ship-issue.sh` | `./ship-issue.sh 42 --auto` | YOLO mode |
| `ship-issues.sh` | `./ship-issues.sh "39,41,42"` | **Batch:** multiple issues sequentially |
| `ship-issues.sh` | `./ship-issues.sh "39,41" --auto` | Batch YOLO mode |
| `ship-issue-no-test.sh` | `./ship-issue-no-test.sh 42` | Skip tests (docs/config) |
| `test-only.sh` | `./test-only.sh` | Run `/test` via Claude CLI |
| `test-only.sh` | `./test-only.sh --fix` | YOLO mode |
| `test-only.sh` | `./test-only.sh "args"` | Pass args to `/test` |

**Scripts that delegate to Claude CLI commands:**
- `test-only.sh` → `/test`

**Scripts with full implementation:**
- `research.sh` - hypothesis-driven research → `research/*.md` file → structured GitHub issue
- `ship-issue.sh` - 6-step workflow (branch → plan → code → post reports → commit → PR)
- `ship-issues.sh` - batch wrapper: process multiple issues sequentially with main reset between each
- `ship-issue-no-test.sh` - same as ship-issue but uses `/code:no-test`

---

## ship-issue.sh Features

**Workflow:**
1. Branch setup from issue title
2. Planning via Claude CLI
3. Implementation via Claude CLI
4. **Post reports** - finds `apps/**/*report*.md`, posts to GitHub issue, deletes files
5. Commit changes (uses `Refs #N` - issue stays open)
6. Create PR + add `shipped` label

**Optimizations:**
- Single GitHub API call (cached with `jq`)
- Issue stays open for manual testing (no `Closes #N`)
- `shipped` label auto-created if missing (purple #7057ff)
- Report files posted then cleaned up (not in final commit)

**Requirements:**
- `gh` (GitHub CLI)
- `jq` (JSON processor)
- `claude` (Claude CLI)

---

## ship-issues.sh (Batch Mode)

**Process multiple issues sequentially with clean isolation.**

```bash
./ship-issues.sh "39,41,42" --auto
```

**Flow:**
1. Parse comma-separated issue numbers
2. For each issue:
   - `git checkout main && git pull` (clean slate)
   - Run `./ship-issue.sh <issue> [--auto]`
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

Based on: "Engineering Report: Autonomous Orchestration of Claude Code CLI"
