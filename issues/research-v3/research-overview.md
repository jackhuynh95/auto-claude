# Research V3 Overview (Opus 4.6 — External Comparison Reconciliation)

Cross-references the external `ralph-claude-code` vs `agent-teams` comparison (screenshot, 2026-03-18) against V2's codebase-grounded analysis. Identifies what the external comparison got right, what it missed about auto-claude's actual state, and what new gaps surface.

## Key Difference from V2

V2 audited internal guardrails and proposed `spawn-worker.sh` + `swarm-commander.sh`. **V3 pressure-tests those proposals against the external comparison's architecture dimensions** — surfacing blind spots in both analyses.

## Topics

- [00 — External vs Internal Reality](./research-00-external-vs-internal-reality.md): Where the screenshot's comparison applies, where auto-claude has already diverged.
- [01 — Blind Spots](./research-01-blind-spots.md): Gaps the screenshot raises that V2 didn't cover. Gaps V2 found that the screenshot ignores.
- [02 — Revised Swarm Design](./research-02-revised-swarm-design.md): Updated architecture incorporating both perspectives.

## Main Takeaway

1. The screenshot frames this as a binary choice (ralph vs agent-teams). **Auto-claude is already a third option** — it took ralph's safety-loop DNA and added label routing, model routing, and composable flags that neither ralph nor agent-teams have.
2. The screenshot correctly identifies **orphan cleanup, cost tracking, and failure isolation** as critical — V2 underweighted these.
3. V2's `spawn-worker.sh` proposal is sound but needs: (a) tmux session cleanup on crash, (b) per-worker cost accumulation, (c) a dead-worker reaper.
4. `agent-teams`' native mailbox (`~/.claude/tasks/`) is interesting but irrelevant — auto-claude's file-based JSON protocol is more portable and debuggable.
5. Total new findings: **3 gaps not in V2, 2 confirmed strengths, 1 design revision**.

## V1 → V2 → V3 Progression

| Aspect | V1 (GPT 5.4) | V2 (Opus 4.6) | V3 (Opus 4.6 + External) |
|---|---|---|---|
| Grounding | Theoretical | Code-grounded | Code-grounded + external comparison |
| Scope | "Build loop first" | "Loop exists. Parallelize." | "Parallelize, but fix orphan/cost/reaper gaps first." |
| Blind spots | Didn't know loop existed | Underweighted failure cleanup | Reconciles both perspectives |
| Architecture | Proposed flow | ASCII of actual state | Actual state + delta from external analysis |
| New code estimate | Not provided | ~120 LOC Bash | ~160 LOC Bash (adds reaper + cost hooks) |
