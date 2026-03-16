# Research V2 Overview (Claude Opus 4.6)

Competing version of the swarm planning research. Grounded in the **actual codebase** rather than theoretical recommendations.

## Key Difference from V1 (GPT 5.4)

V1 recommended building a stable loop first. **The loop already exists.** This version audits what's implemented, identifies the real gaps, and proposes concrete next steps with line-count estimates.

## Topics

- [00 — Swarm Direction](./research-00-swarm-direction.md): Where the repo actually stands. What's built vs what's missing.
- [01 — Loop Guardrails](./research-01-loop-guardrails.md): Audit of existing guardrails (with file:line references) + prioritized gaps.
- [02 — Swarm Orchestration](./research-02-swarm-orchestration.md): tmux-based parallel worker system. 3 new scripts, 0 rewrites.
- [03 — Bash Architecture Sketch](./research-03-bash-architecture-sketch.md): ASCII architecture diagram of current state + concrete evolution steps.

## Main Takeaway

1. The foundation is already live — label routing, model routing, retry loops, fallback tools
2. The **real next step** is parallelism: `spawn-worker.sh` (~40 LOC) + `swarm-commander.sh` (~80 LOC)
3. Before parallel: add wall-clock timeouts and spin detection to existing scripts
4. Bash stays as orchestration layer. Python/Node only enters when we need persistent queues or webhooks.
5. Total new code for swarm capability: **~120 lines of Bash**

## V1 vs V2 Comparison

| Aspect | V1 (GPT 5.4) | V2 (Claude Opus 4.6) |
|---|---|---|
| Grounding | Theoretical — references external repos | Code-grounded — references actual files + line numbers |
| Guardrails | Lists desirable guardrails | Audits existing ones, identifies gaps with priority |
| Architecture | Proposed flow diagram | ASCII diagram of actual current architecture |
| Recommendations | "Build loop first" | "Loop exists. Add timeout + spin detection. Then parallelize." |
| Specificity | Component names | Component names + line counts + code snippets |
| Phasing | 3 abstract phases | 4 concrete steps with files to create/modify |
| New code estimate | Not provided | ~120 lines of Bash |
