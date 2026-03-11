# Auto-Claude

Autonomous issue processing pipeline powered by Claude Code CLI + [ClaudeKit Engineer](https://github.com/claudekit).

```
GitHub Issues → looper.sh → fix-issue.sh / ship-issue.sh → PR
```

**[→ Full Pipeline Guide](docs/PIPELINE.md)**

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
- [ClaudeKit Engineer](https://github.com/claudekit) — provides `/plan`, `/code`, `/fix`, `/test` slash commands

---

See **[docs/PIPELINE.md](docs/PIPELINE.md)** for the full reference: labels, flags, profiles, model routing, and scripts.
