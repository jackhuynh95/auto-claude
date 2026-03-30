# Merge Strategy: CK Watch + Auto-Claude

---

## Option A: CK Watch as Orchestrator, Auto-Claude Scripts as Plugins

**Approach**: Use CK's Node.js daemon as the watcher/orchestrator layer. Replace its built-in phases with calls to our bash scripts.

```
ck watch (daemon)
  ├── Phase: Discovery      → CK's issue-poller (keep)
  ├── Phase: Brainstorm     → brainstorm-issue.sh (ours)
  ├── Phase: Planning       → ship-issue.sh step_2 (ours)
  ├── Phase: Approval       → CK's approval-checker (keep)
  ├── Phase: Implementation → fix-issue.sh OR ship-issue.sh (ours)
  ├── Phase: E2E Test       → verify-issue.sh (ours, CK doesn't have)
  ├── Phase: Slack Report   → report-issue.sh (ours, CK doesn't have)
  └── Phase: PR Creation    → ship-issue.sh step_5 (ours)
```

**Pros**: Get CK's daemon stability, state persistence, approval gates
**Cons**: Dependency on CK repo. Must adapt CK's phase interface. Two runtimes (Node + Bash).

---

## Option B: Keep Auto-Claude Bash Scripts, Adopt CK Patterns

**Approach**: Stay bash-native. Cherry-pick valuable patterns from CK into our existing scripts.

### Patterns to Adopt:
1. **State file** (`.auto-claude.json`): Track processing state per issue for crash recovery
2. **Timeout enforcement**: Wrap `claude -p` calls with timeout + SIGTERM/SIGKILL
3. **Rate limiting**: Track API calls per hour, pause when nearing limit
4. **Approval gate**: New `--approve` flag that pauses for maintainer comment before /code

### What Stays the Same:
- All existing scripts (looper, fix, ship, verify, report, brainstorm, read-issue)
- Label-based routing (simpler than .ck.json status tracking)
- Composable flags
- Scheduling profiles
- Model routing

**Pros**: No external dependency. Incremental improvement. Maintains bash simplicity.
**Cons**: Miss CK's daemon advantages (always-on, crash recovery is harder in bash).

---

## Option C: Hybrid — CK Watch Overnight, Auto-Claude Daytime (Jack's Scenario)

**Approach**: Run both. CK handles overnight watching, auto-claude handles daytime ops.

```
Night (CK watch):
  1. CK daemon polls issues continuously
  2. CK runs implementation phases
  3. CK creates PRs via its built-in flow

Morning (Auto-Claude):
  1. read-issue.sh → extract tasks from Slack
  2. verify-issue.sh → E2E test overnight PRs
  3. report-issue.sh → summarize to Slack

Day (Auto-Claude):
  1. Jack corrects/refines tasks
  2. looper.sh --profile daytime
  3. fix-issue.sh / ship-issue.sh for specific issues
```

**Pros**: Best of both worlds. No code merge needed. CK watches, we verify + report.
**Cons**: Two systems to maintain. Potential conflicts if both touch same issues.

---

## Recommendation: Option B (Adopt Patterns) + Option C (Hybrid Runtime)

### Phase 1 — Immediate (v2.0.0 scope)
Adopt CK's best patterns into auto-claude:
- [ ] State file for crash recovery (`.auto-claude.json`)
- [ ] Timeout wrapper for `claude -p` calls
- [ ] Rate limiting counter

### Phase 2 — When CK is stable
Run CK watch overnight alongside auto-claude daytime:
- [ ] Configure CK watch for target repo
- [ ] Verify CK PRs with `verify-issue.sh` each morning
- [ ] Report via `report-issue.sh`

### Key Principle
**CK covers ship_issue.sh already** — agree. But our moat is:
- E2E testing (agent-browser)
- Slack integration (read + report)
- Debug → Fix → Test loop
- Smart routing (labels, model, flags)
- Scheduling profiles

These are the things CK's team didn't build because they're specific to our workflow.

---

## Script-by-Script Overlap Analysis

| Auto-Claude Script | CK Equivalent | Keep/Replace/Merge |
|---|---|---|
| `looper.sh` | `ck watch` daemon | **Keep** — label routing + profiles are unique |
| `ship-issue.sh` | `implementation-runner.ts` | **Keep** — /plan:fast + /code:auto + model routing |
| `fix-issue.sh` | None | **Keep** — debug→fix→test loop doesn't exist in CK |
| `verify-issue.sh` | None | **Keep** — E2E via agent-browser is our moat |
| `report-issue.sh` | None | **Keep** — Slack Bot API reporting is our moat |
| `read-issue.sh` | None | **Keep** — Slack reading doesn't exist in CK |
| `brainstorm-issue.sh` | None | **Keep** — /brainstorm→/issue pipeline is ours |
| `looper-profiles.sh` | None | **Keep** — scheduling profiles are unique |
| `setup-labels.sh` | None | **Keep** — label infrastructure for routing |

**Result**: Keep all scripts. Enhance with CK patterns (state, timeout, rate limit).
