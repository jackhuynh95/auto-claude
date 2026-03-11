# Issue 02: GitHub Label Pipeline Setup

## Summary

Define and create the standard set of GitHub labels that drive the looper pipeline. Labels on issues act as the Kanban columns — no separate board needed.

## Motivation

Thierry's insight: "Instead of a Kanban board, you can just use labels on the GitHub issues and they will get picked up." Labels are lightweight, already built into GitHub, and queryable via `gh`.

## Spec

### Labels to Create

| Label | Color | Description |
|-------|-------|-------------|
| `ready_for_dev` | `#0E8A16` (green) | Triaged and ready for Claude to fix |
| `ready_for_test` | `#FBCA04` (yellow) | Fix shipped, needs e2e verification |
| `shipped` | `#7057FF` (purple) | PR created, awaiting merge |
| `verified` | `#1D76DB` (blue) | E2e passed, can close |
| `blocked` | `#D93F0B` (red) | Blocked, skip in pipeline |
| `pipeline` | `#C5DEF5` (light blue) | Meta: issue is in the automated pipeline |

### Setup Script

```bash
# .claude/scripts/setup-labels.sh
gh label create "ready_for_dev" --description "Ready for automated fix" --color "0E8A16" --force
gh label create "ready_for_test" --description "Fix shipped, needs e2e" --color "FBCA04" --force
gh label create "shipped" --description "PR created" --color "7057FF" --force
gh label create "verified" --description "E2e passed" --color "1D76DB" --force
gh label create "blocked" --description "Blocked, skip in pipeline" --color "D93F0B" --force
gh label create "pipeline" --description "In automated pipeline" --color "C5DEF5" --force
```

### Label Transitions

```
[new issue] + "pipeline" + "ready_for_dev"
       │
       ▼
  fix-issue.sh succeeds → remove "ready_for_dev", add "ready_for_test"
       │
       ▼
  e2e-test passes → remove "ready_for_test", add "verified", close issue
  e2e-test fails  → remove "ready_for_test", add "ready_for_dev" (re-queue)
```

### Monitoring

- **GitHub**: Filter issues by label to see pipeline status
- **Slack/logs**: Looper posts summary to `#log-nois-medusa-pipeline`

## Acceptance Criteria

- [ ] `setup-labels.sh` creates all labels idempotently (`--force`)
- [ ] Labels documented in this file
- [ ] Transition rules documented for looper to follow
