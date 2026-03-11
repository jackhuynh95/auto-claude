# Looper Pipeline — Issue Tracker

## Architecture

```
/loop (Claude Code built-in)
  └─→ looper.sh (commander script)
        ├─→ Scans GitHub issues by label
        ├─→ Dispatches fix-issue.sh with flags
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

## Build Order

```
Phase 1 (foundations — no dependencies):
  02-label-pipeline    ← create labels on GitHub
  03-worktree-flag     ← enhance fix-issue.sh
  04-e2e-flag          ← enhance fix-issue.sh

Phase 2 (the looper):
  01-looper-script     ← ties everything together

Phase 3 (polish):
  05-looper-scheduling ← profiles for different times
  06-frontend-design   ← manual gate flag
```

## Key Decisions

- **Labels over Kanban board** — Thierry's suggestion. Labels are queryable, lightweight, no extra tooling.
- **Flags are composable** — `--auto --worktree --e2e --hard` can all combine.
- **Frontend design is user-controlled** — looper never auto-triggers it.
- **E2E failure re-queues** — failed test moves issue back to `ready_for_dev`.
