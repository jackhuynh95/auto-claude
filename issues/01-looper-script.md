# Issue 01: Looper Script — GitHub Issue Scanner & Dispatcher

## Summary

Create a looper shell script that scans GitHub issues by label and dispatches the right action for each. This is the **commander** that `/loop` calls on an interval.

## Motivation

Currently `fix-issue.sh` requires manually passing an issue number. The looper automates issue discovery and routing based on GitHub labels, enabling 24/7 unattended operation.

## Spec

### Location

```
.claude/scripts/looper.sh
```

### Behavior

1. **Scan** — `gh issue list` filtered by pipeline labels
2. **Route** — Based on label, call the right script with the right flags
3. **Transition** — After action completes, move the issue to the next label stage
4. **Log** — All actions logged to `logs/looper-<timestamp>.log`

### Label → Action Mapping

| Label | Action | Flags |
|-------|--------|-------|
| `ready_for_dev` | `fix-issue.sh <num>` | `--auto --worktree` |
| `ready_for_test` | Run e2e-test skill | `--e2e` |
| `shipped` | (no action, waiting for test) | — |
| `verified` | Close issue | — |
| `blocked` | Skip, log warning | — |

### CLI Usage

```bash
# Manual run
./looper.sh

# Via /loop (every 2 hours, for 3 days)
/loop 2h "bash .claude/scripts/looper.sh"

# Control intervals
./looper.sh --label ready_for_dev   # only process dev-ready issues
./looper.sh --dry-run               # scan but don't execute
./looper.sh --limit 3               # process max 3 issues per run
```

### Flow

```
/loop interval
  └─→ looper.sh
        ├─→ gh issue list --label "ready_for_dev"
        │     └─→ fix-issue.sh <num> --auto --worktree
        │           └─→ on success: label → "ready_for_test"
        ├─→ gh issue list --label "ready_for_test"
        │     └─→ run e2e-test for the issue
        │           └─→ on pass:  label → "verified", close issue
        │           └─→ on fail:  label → "ready_for_dev" (re-fix)
        └─→ log summary
```

## Dependencies

- Issue 02 (label pipeline setup)
- Issue 03 (worktree flag on fix-issue.sh)
- Issue 04 (e2e flag on fix-issue.sh)

## Acceptance Criteria

- [ ] `looper.sh` scans issues by label and dispatches correctly
- [ ] `--dry-run` mode prints what would happen without executing
- [ ] `--limit N` caps issues processed per run
- [ ] Logs written to `logs/`
- [ ] Works when called from `/loop`
