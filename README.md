# Auto-Claude

Autonomous issue processing pipeline powered by Claude Code CLI + [ClaudeKit Engineer](https://github.com/claudekit).

```
read-slack.sh (planned) → brainstorm-issue.sh → /issue → looper.sh → fix/ship → PR → report-issue.sh → Slack
                                                   └─→ verify-issue.sh → e2e → verified
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
.auto-claude/fix-issue.sh 42              # Fix: /debug → /fix → /test
.auto-claude/fix-issue.sh 42 --hard       # Fix: /fix:hard → /test (skip debug)
.auto-claude/ship-issue.sh 42             # Ship feature: plan(opus) → code(sonnet) → PR
.auto-claude/ship-issue.sh 42 --validate  # Validate plan before coding
.auto-claude/verify-issue.sh 42           # E2E verify a ready_for_test issue
.auto-claude/ship-issues.sh "1,2,3"       # Batch ship
```

---

## Quick Start

```bash
# 0. Copy template to your project's CLAUDE.md
cp CLAUDE.template.md CLAUDE.md

# 1. Create pipeline labels on GitHub (once)
./setup-labels.sh

# 2. Queue an issue (pick one)
/issue "Add dark mode toggle"                          # recommended — interactive
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev"  # manual

# 3. Run
./looper.sh --dry-run                    # preview
./looper.sh                              # process
/loop 2h ./looper.sh --profile overnight # automated
```

## Composable Flags

All flags work on both `fix-issue.sh` and `ship-issue.sh`:

| Flag | Description |
|------|-------------|
| `--auto` | YOLO mode — skip permission prompts |
| `--hard` | Use Opus directly (complex bugs) |
| `--e2e` | Run e2e after fix/ship — gates PR on pass |
| `--frontend-design` | UI review after fix/ship (report only) |
| `--validate` | Run plan validation before implementation |
| `--no-test` | Skip tests (docs, configs, trivial changes) |
| `--codex` / `--opencode` | Fallback tool if Claude fails |

## Requirements

- `claude` (Claude Code CLI)
- `gh` (GitHub CLI)
- `jq`
- `git` with push access
- [ClaudeKit Engineer](https://github.com/claudekit) — provides `/plan`, `/code`, `/fix`, `/test` slash commands

---

See **[docs/PIPELINE.md](docs/PIPELINE.md)** for the full reference: labels, flags, profiles, model routing, and scripts.
