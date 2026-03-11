# Looper Pipeline — Issue Tracker

## Architecture

```
/loop (Claude Code built-in)
  └─→ looper.sh (commander script)
        ├─→ Scans GitHub issues by label
        ├─→ Routes by title prefix: [BUG] → fix, [FEATURE] → ship
        ├─→ Skips [WONTFIX] / [WONTFEAT]
        ├─→ Bugs processed first (priority)
        ├─→ Transitions labels after completion
        └─→ Logs everything

GitHub Issue Labels = Kanban Columns
  ready_for_dev → ready_for_test → verified → closed
```

## Issues

| # | Title | Status | Priority | Depends On |
|---|-------|--------|----------|------------|
| 01 | [Looper Script](./01-looper-script.md) | done | high | 02, 03, 04 |
| 02 | [Label Pipeline Setup](./02-label-pipeline.md) | done | high | — |
| 03 | [Worktree Flag](./03-worktree-flag.md) | done | high | — |
| 04 | [E2E Flag](./04-e2e-flag.md) | done | medium | — |
| 05 | [Scheduling Profiles](./05-looper-scheduling.md) | done | medium | 01, 02 |
| 06 | [Frontend Design Flag](./06-frontend-design-flag.md) | done | low | — |
| 07 | [Model Routing](./07-model-routing.md) | done | high | — |

## Implemented Files

| Issue | File(s) |
|-------|---------|
| 01 — Looper | `looper.sh` (root) |
| 02 — Labels | `setup-labels.sh` (root) |
| 03 — Worktree | `fix-issue.sh`, `ship-issue.sh` (`--worktree` flag) |
| 04 — E2E | `fix-issue.sh`, `ship-issue.sh` (`--e2e`, `--e2e-only` flags) |
| 05 — Profiles | `looper-profiles.sh` (root), built-in profiles in `looper.sh` |
| 06 — Frontend Design | `fix-issue.sh`, `ship-issue.sh` (`--frontend-design` flag) |
| 07 — Model Routing | `fix-issue.sh`, `ship-issue.sh` (`--model` flag, auto sonnet/opus) |

## Key Decisions

- **Labels over Kanban board** — Thierry's suggestion. Labels are queryable, lightweight, no extra tooling.
- **Flags are composable** — `--auto --worktree --e2e --hard` can all combine.
- **Frontend design is user-controlled** — looper never auto-triggers it.
- **E2E failure re-queues** — failed test moves issue back to `ready_for_dev`.
- **Issue type routing** — `[BUG]` → fix-issue.sh, `[FEATURE/ENHANCEMENT]` → ship-issue.sh, `[WONTFIX/WONTFEAT]` → skipped.
- **Bugs before features** — priority ordering per CLAUDE.md.
- **All scripts at root** — consistent structure, no `.claude/scripts/`.
- **Both fix + ship get all flags** — `ship-issues.sh` passes all flags through.
