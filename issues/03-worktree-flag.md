# Issue 03: Add `--worktree` Flag to fix-issue.sh

## Summary

Add a `--worktree` flag to `fix-issue.sh` that runs the fix in an isolated git worktree instead of the main working directory. This enables parallel issue fixing without conflicts.

## Motivation

When the looper picks up multiple `ready_for_dev` issues, they can't all run in the same working tree. Worktrees let each fix run in isolation — separate branch, separate directory, no conflicts.

## Spec

### Flag

```bash
./fix-issue.sh 42 --auto --worktree
```

### Behavior

1. **Create worktree** — `git worktree add /tmp/fix-issue-42 -b fix/issue-42-slug`
2. **Run fix** — Execute the fix loop inside the worktree directory
3. **Commit & push** — From the worktree
4. **Create PR** — Same as current flow
5. **Cleanup** — `git worktree remove /tmp/fix-issue-42` after PR is created

### Implementation

In `fix-issue.sh`, after branch name is determined:

```bash
if [[ "$WORKTREE_MODE" == "true" ]]; then
    WORKTREE_DIR="/tmp/fix-issue-${ISSUE_NUM}"
    git worktree add "$WORKTREE_DIR" -b "$branch" 2>/dev/null || {
        git worktree remove "$WORKTREE_DIR" --force 2>/dev/null
        git worktree add "$WORKTREE_DIR" -b "$branch"
    }
    cd "$WORKTREE_DIR"
    # ... run fix loop in this directory ...
    # cleanup after PR
    cd "$PROJECT_ROOT"
    git worktree remove "$WORKTREE_DIR"
fi
```

### Existing Reference

There's already a worktree utility at `.claude/scripts/worktree.cjs` — reuse patterns from there.

## Dependencies

None (standalone enhancement to fix-issue.sh)

## Acceptance Criteria

- [ ] `--worktree` flag creates isolated worktree for the fix
- [ ] Fix loop runs entirely within the worktree
- [ ] Worktree is cleaned up after PR creation
- [ ] Works with `--auto` and `--hard` flags simultaneously
- [ ] Handles case where worktree already exists (cleanup + recreate)
