# Auto-Claude Quick Reference

Quick reference for day-to-day pipeline use.

---

## Pipeline Requirements (Both Required)

| Requirement | Example | Purpose |
|---|---|---|
| Labels | `pipeline` + `ready_for_dev` | Opt-in gate — looper ignores without both |
| Title prefix | `[BUG] ...`, `[FEATURE] ...` | Routing — determines which script runs |

Missing either = issue is ignored or misrouted.

---

## Title Prefix → Script Routing

| Prefix | Script | Notes |
|---|---|---|
| `[BUG]` | `fix-issue.sh` | — |
| `[FEATURE]` | `ship-issue.sh` | — |
| `[ENHANCEMENT]` | `ship-issue.sh` | — |
| `[CHORE]` | `ship-issue.sh` | `--no-test` auto |
| `[DOCS]` | `ship-issue.sh` | `--no-test` auto |
| `[WONTFIX]` / `[WONTFEAT]` | skipped | — |

---

## Run Modes

```bash
# One-shot (manual, cron, CI)
./looper.sh                                        # full scan (all labels)
./looper.sh --dry-run                              # preview only
./looper.sh --label ready_for_dev                  # single label
./looper.sh --label "ready_for_dev,ready_for_test" # multiple labels
./looper.sh --read-slack                           # Slack → brainstorm → issue first

# Recurring (Claude Code built-in /loop)
/loop 2h ./looper.sh --profile overnight
/loop 4h ./looper.sh --profile daytime
/loop 1h ./looper.sh --profile continuous
/loop 4h ./looper.sh --read-slack --profile morning
```

`looper.sh` is always stateless — scans and dispatches once per execution.
`/loop` is the Claude Code built-in that re-runs it on interval.
`--read-slack` runs `read-issue.sh` (claude /slack-read → brainstorm) before the label scan.
After successful fix/ship/verify, `report-issue.sh` auto-reports to Slack.

---

## Composable Flags

```bash
./fix-issue.sh 42 --auto                    # YOLO, no prompts
./fix-issue.sh 42 --auto --hard             # Opus model, complex bugs
./fix-issue.sh 42 --auto --worktree         # isolated /tmp/fix-issue-42
./fix-issue.sh 42 --auto --e2e              # run e2e, gates PR on pass
./fix-issue.sh 42 --auto --worktree --e2e   # full isolated pipeline
./ship-issue.sh 42 --auto --validate        # validate plan before coding
```

`--worktree` — runs in isolated `/tmp/fix-issue-<num>`, auto-cleaned after.
`--validate` — runs `/plan:validate` after planning, gates implementation.
`--frontend-design` — UI review only, **manual** (never auto-triggered).

---

## Quick Issue Queue

```bash
# Standard
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev"

# Complex bug (Opus)
gh issue edit 42 --add-label "pipeline" --add-label "ready_for_dev" --add-label "hard"

# Batch
for num in 42 43 44; do
  gh issue edit $num --add-label "pipeline" --add-label "ready_for_dev"
done
```

---

## Pipeline Stages (Label Flow)

```
read-issue.sh (claude /slack-read → brainstorm-issue.sh → GitHub issue)
ready_for_dev → fix-issue.sh / ship-issue.sh → ready_for_test
ready_for_test → verify-issue.sh (e2e) → verified → closed
                                       → ready_for_dev (fail, re-queued)
verified/closed → report-issue.sh → Slack
```

---

## Model & Effort Routing

| Phase | Model | Effort |
|---|---|---|
| `/brainstorm` | Opus | max |
| `/plan`, `/debug` | Opus | high |
| `/issue` | Sonnet | medium |
| `/fix`, `/code`, `e2e-test` | Sonnet | default |
| `--hard` flag | Opus | high |

Effort: `low` → `medium` → `high` → `max`. Saves ~60–70% tokens vs all-Opus.
