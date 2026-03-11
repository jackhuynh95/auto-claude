# Issue 05: Looper Scheduling Profiles (Midnight, Morning, Continuous)

## Summary

Define scheduling profiles for the looper so it can run different strategies at different times — heavy work overnight, light checks in the morning, continuous monitoring during the day.

## Motivation

"Loop directory obtains some script as commander/leader/interval until right time spawn the claude script." Different times of day call for different behaviors — batch processing at night, quick checks in the morning.

## Spec

### Profiles

| Profile | Interval | What it does |
|---------|----------|--------------|
| `overnight` | Every 2h, 10pm–6am | Process all `ready_for_dev` issues aggressively (`--auto --hard`) |
| `morning` | Once at 7am | Summary report, process `ready_for_test` with e2e |
| `daytime` | Every 4h, 8am–8pm | Light scan, only `ready_for_test` verification |
| `continuous` | Every 1h, 24/7 | Full pipeline scan (default) |

### Usage

```bash
# Via /loop with profiles
/loop 2h "bash .claude/scripts/looper.sh --profile overnight"
/loop 4h "bash .claude/scripts/looper.sh --profile daytime"

# Morning summary (one-shot)
bash .claude/scripts/looper.sh --profile morning --dry-run
```

### Profile Config

```bash
# .claude/scripts/looper-profiles.sh (sourced by looper.sh)

profile_overnight() {
    LABELS="ready_for_dev"
    FLAGS="--auto --hard --worktree"
    LIMIT=5
}

profile_morning() {
    LABELS="ready_for_test"
    FLAGS="--e2e-only"
    LIMIT=10
    SUMMARY=true
}

profile_daytime() {
    LABELS="ready_for_test"
    FLAGS="--e2e-only"
    LIMIT=3
}

profile_continuous() {
    LABELS="ready_for_dev,ready_for_test"
    FLAGS="--auto --worktree"
    LIMIT=3
}
```

### Summary Report (Morning Profile)

```
═══════════════════════════════════════
  Pipeline Summary — 2026-03-11 07:00
═══════════════════════════════════════
  ready_for_dev:   3 issues
  ready_for_test:  2 issues
  shipped:         5 issues
  verified:        8 issues (last 24h)
  blocked:         1 issue
═══════════════════════════════════════
```

## Dependencies

- Issue 01 (looper.sh exists)
- Issue 02 (labels exist)

## Acceptance Criteria

- [ ] `--profile` flag selects scheduling behavior
- [ ] Profiles define: labels to scan, flags to pass, issue limit
- [ ] Morning profile generates summary report
- [ ] Profiles are configurable via `looper-profiles.sh`
