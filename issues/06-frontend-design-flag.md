# Issue 06: `--frontend-design` Flag — Controlled UI Review Step

## Summary

Add a `--frontend-design` flag that triggers a UI/design review step using the existing `frontend-design` skill. This flag is **user-controlled** — the looper won't auto-enable it; only Jack decides when design review is needed.

## Motivation

"I need to be able to use `/frontend-design/` flag, new, controlled or decided by me." Not every fix needs a design review. This is a manual gate that can be added to specific issues or invoked explicitly.

## Spec

### Flag

```bash
./fix-issue.sh 42 --auto --frontend-design    # fix + design review
./fix-issue.sh 42 --frontend-design-only       # design review only
```

### Behavior

After fix (or standalone), invoke the `frontend-design` skill:

1. Take screenshots of affected pages
2. Run design review against the UI
3. Report findings as issue comment
4. Do NOT auto-fix design issues — report only (user decides)

### Label Integration (Optional)

If an issue has label `needs_design_review`:
- Looper flags it but does NOT auto-process
- Shows in morning summary as requiring manual attention

### Implementation

```bash
step_2d_frontend_design() {
    info "Step 2d: Frontend Design Review"

    run_claude "Use the frontend-design skill to review the UI changes for issue #$ISSUE_NUM.
Take screenshots and report any design issues. Do not auto-fix."
}
```

## Dependencies

- `frontend-design` skill (already exists at `.claude/skills/frontend-design/`)

## Acceptance Criteria

- [ ] `--frontend-design` flag triggers design review after fix
- [ ] `--frontend-design-only` runs review standalone
- [ ] Results posted as issue comment
- [ ] Not auto-triggered by looper — user-controlled only
- [ ] `needs_design_review` label shows in summary but is not auto-processed
