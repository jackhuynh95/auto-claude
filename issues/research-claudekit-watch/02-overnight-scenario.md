# Jack's Overnight Scenario

---

## The Vision

```
Morning & Afternoon:
  1. Jack runs read-issue.sh → Slack Reader extracts tasks
  2. Tasks created as GitHub issues via brainstorm-issue.sh
  3. Jack corrects/refines all issues manually

Evening:
  4. Jack starts #medusa-agent-swarm with CK watcher
     - CK watch monitors issues overnight
     - Auto-claude looper handles E2E + Slack reporting

Next Morning:
  5. Results ready — PRs created, E2E verified, Slack summarized
```

---

## Detailed Flow

### Phase 1: Task Creation (Jack, Daytime)
```bash
# Read Slack for tasks
./read-issue.sh --channel "#medusa" --since "09:00" --before "17:00"

# Jack reviews and corrects extracted tasks
# Then brainstorm each into proper GitHub issues
./brainstorm-issue.sh "Add wishlist plugin" --type feature --auto
./brainstorm-issue.sh "Fix checkout timeout" --type bug --auto

# Label them for pipeline
gh issue edit 155 --add-label "ready_for_dev"
gh issue edit 156 --add-label "ready_for_dev"
```

### Phase 2: Overnight Execution (Automated)
```bash
# Option A: CK watch daemon
ck watch --repo owner/repo --auto-approve false

# Option B: Auto-claude looper (what we have today)
/loop 2h ./looper.sh --profile overnight --auto

# Option C: Hybrid — CK watches, looper verifies
# Terminal 1: CK watch running
# Terminal 2: /loop 3h ./looper.sh --label ready_for_test --auto
```

### Phase 3: Morning Verification (Automated/Jack)
```bash
# Verify all overnight PRs with E2E
./looper.sh --label ready_for_test --auto

# Report results to Slack
./report-issue.sh 155 --auto
./report-issue.sh 156 --auto

# Or batch via looper morning profile
./looper.sh --profile morning --auto
```

---

## What CK Watch Handles in This Scenario
- Continuous issue polling
- Implementation with approval gates
- State persistence (if crash, resumes)
- PR creation

## What Auto-Claude Handles (CK Can't)
- Slack reading (task extraction)
- Brainstorm → issue creation
- E2E verification (agent-browser)
- Slack reporting (results to team)
- Label transitions (pipeline routing)
- Scheduling profiles (overnight vs morning)

---

## The Challenge

CK watch's phase system expects to own the full lifecycle:
`new → brainstorming → planning → awaiting_approval → implementing → completed`

Injecting our scripts means either:
1. **Hook into CK phases**: Add custom phases for E2E, Slack, etc.
2. **Run alongside CK**: Let CK do implementation, we do verification
3. **Replace CK's orchestrator**: Use our looper.sh, adopt CK's subprocess pattern

Option 2 (run alongside) is safest to start — no code merge needed.
