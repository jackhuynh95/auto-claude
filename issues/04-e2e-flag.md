# Issue 04: Add `--e2e` Flag to fix-issue.sh

## Summary

Add an `--e2e` flag that runs the `e2e-test` skill after a successful fix to verify the fix didn't break anything. The looper uses this for the `ready_for_test` pipeline stage.

## Motivation

The `e2e-test` skill already exists with full browser-based testing. Connecting it as a post-fix verification step closes the loop: fix → test → verify → ship.

## Spec

### Flag

```bash
./fix-issue.sh 42 --auto --e2e          # fix then e2e
./fix-issue.sh 42 --e2e-only            # skip fix, just run e2e (for ready_for_test)
```

### Behavior

#### `--e2e` (after fix)

After step 2 (fix loop) succeeds, add a new step:

1. Run pre-flight checks (services running?)
2. Execute relevant e2e scenarios
3. If pass → continue to commit/PR
4. If fail → log failure, skip PR creation

#### `--e2e-only` (standalone test)

For issues labeled `ready_for_test` — the fix is already done, just verify:

1. Check out the fix branch
2. Run e2e scenarios
3. If pass → label `verified`, close issue
4. If fail → label `ready_for_dev` (re-queue for fix)

### E2E Integration

```bash
step_2c_e2e() {
    info "Step 2c: E2E Verification"

    # Pre-flight: check services
    curl -sf http://localhost:9000/health || {
        warn "Medusa API not running - skipping e2e"
        return 1
    }

    # Run e2e via Claude with the e2e-test skill
    run_claude "Run e2e-test scenarios to verify fix for issue #$ISSUE_NUM: $ISSUE_TITLE.
Use the e2e-test skill. Run these scenarios: create-account, purchase-success.
Report pass/fail."

    # Check result
    # ...
}
```

### Scenario Selection

The looper can optionally specify which scenarios to run based on issue labels or content:

- Default: `create-account` + `purchase-success` (smoke test)
- Full: all scenarios in `.claude/skills/e2e-test/scenarios/`
- Custom: parse issue body for `e2e-scenarios: [list]`

## Dependencies

- `e2e-test` skill (already exists)
- Services must be running (Medusa API, storefront, admin, PostgreSQL)

## Acceptance Criteria

- [ ] `--e2e` flag runs e2e after fix, gates PR creation on pass
- [ ] `--e2e-only` flag runs e2e without fixing (for test-only pipeline stage)
- [ ] Pre-flight checks verify services before running e2e
- [ ] E2e results logged
- [ ] Integrates with label transitions (pass → verified, fail → re-queue)
