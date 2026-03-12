# Auto-Claude

Autonomous issue processing pipeline powered by Claude Code CLI + [ClaudeKit Engineer](https://github.com/claudekit).

```
GitHub Issues → looper.sh → fix-issue.sh / ship-issue.sh → PR
```

**[→ Full Pipeline Guide](docs/PIPELINE.md)**

> Claude can't run itself through .md files. The bash scripts are the true autonomous implementation.

---

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
.auto-claude/fix-issue.sh 42         # Fix: /debug → /fix → /test
.auto-claude/fix-issue.sh 42 --hard  # Fix: /fix:hard → /test (skip debug)
.auto-claude/ship-issue.sh 42 --validate  # Validate plan before coding
.auto-claude/ship-issues.sh "1,2,3"  # Batch ship
```

---

## Quick Start

```bash
# 0. Copy template to your project's CLAUDE.md
cp CLAUDE.template.md CLAUDE.md

# 1. Create pipeline labels on GitHub (once)
./setup-labels.sh

# 2. Queue an issue
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev"

# 3. Run
./looper.sh --dry-run        # preview
./looper.sh                  # process
/loop 2h ./looper.sh --profile overnight   # automated
```

## Requirements

- `claude` (Claude Code CLI)
- `gh` (GitHub CLI)
- `jq`
- `git` with push access
- [ClaudeKit Engineer](https://github.com/claudekit) (paid) — provides `/plan`, `/code`, `/fix`, `/test` slash commands

---

See **[docs/PIPELINE.md](docs/PIPELINE.md)** for the full reference: labels, flags, profiles, model routing, and scripts.
