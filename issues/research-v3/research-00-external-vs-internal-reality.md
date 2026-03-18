# Research 00: External Comparison vs Auto-Claude's Internal Reality

## The Screenshot's Frame: Ralph vs Agent-Teams (Binary Choice)

The external comparison (2026-03-18) presents two approaches as mutually exclusive:
- **`ralph-claude-code`**: Custom Bash safety wrapper for a single continuous agent
- **`agent-teams`**: Built-in Claude Code orchestrator for parallel native agents

## Auto-Claude: The Third Path (Already Built)

Auto-claude is neither. It took ralph's `while`-loop DNA and evolved it into a **label-driven, model-routing, multi-script pipeline** that the screenshot's comparison doesn't account for.

### Dimension-by-Dimension Reality Check

| Feature / Dimension | Screenshot says (Ralph) | Screenshot says (Agent-Teams) | Auto-Claude Reality |
|---|---|---|---|
| **Core Architecture** | `while` loop → `claude` CLI | Built-in Lead+Teammate binary | **4-script pipeline** (`looper.sh` → `fix-issue.sh` / `ship-issue.sh` / `verify-issue.sh`) with label routing and profile-based scheduling. Not a raw `while` loop anymore. |
| **Primary Goal** | Unattended autonomy | Parallel execution | **Both.** Unattended overnight runs (looper profiles) AND parallel execution is the proposed next step (V2's swarm-commander). |
| **Model Ecosystem** | Agnostic (wrap any CLI) | Locked to Anthropic | **Agnostic AND structured.** Model routing per task type: Sonnet for fixes, Opus for reasoning, Codex/OpenCode as fallback. Already implemented in `fix-issue.sh:84-94`. |
| **How tmux is Used** | Infrastructure (detached session) | UI (split panes) | **Infrastructure.** V2 proposes tmux for worker isolation, not display. Matches ralph's approach. |
| **Agent Communication** | File-based (grep .log) | Native mailbox (~/.claude/tasks/) | **File-based but structured.** V2 proposes JSON status files (`worker-{issue}-status.json`), not raw log grepping. More reliable than ralph, more portable than agent-teams. |
| **Safety & Guardrails** | High / Hardcoded | Basic / LLM-Dependent | **High AND composable.** Lock files, retry limits, build validation gates, false-positive detection, model escalation. V2 identified P0-P4 gaps still to fill. |
| **Token Cost & Overhead** | Standard (single agent) | Very High (every teammate has own context) | **Standard today** (serial). Would increase with parallel workers but each worker is still a single `claude` call, not a Lead+N Teammates architecture. |
| **Failure State** | Bash catches, exits safely | Orphaned tmux sessions | **Bash catches** (existing). V2's tmux workers introduce orphan risk — **this is a real gap the screenshot correctly flags.** |

## Where the Screenshot is Right

1. **Orphan risk is real.** V2 proposes tmux workers but doesn't address crash cleanup. If `swarm-commander.sh` dies, spawned tmux sessions persist invisibly.

2. **Cost tracking matters for parallel.** Moving from 1 serial agent to 3 parallel workers 3x's the token burn rate. The screenshot's "Very High" warning for agent-teams applies to any parallel approach, including ours.

3. **File-based > native mailbox for our use case.** The screenshot frames file-based communication as inferior. It's actually superior for auto-claude: JSON status files are debuggable with `cat`/`jq`, work across any CLI tool, and don't depend on Claude Code internals.

## Where the Screenshot is Wrong (About Our Situation)

1. **"Binary choice" framing.** Auto-claude already has the best of both: ralph's safety patterns + structured multi-script orchestration. We're not choosing between them — we've already merged the useful parts.

2. **"Locked to Anthropic" for agent-teams.** True for agent-teams, but irrelevant — auto-claude's model routing already supports Codex and OpenCode as fallback CLIs. The screenshot's recommendation to "build upon ralph for CLI freedom" is advice we've already followed.

3. **"Ralph requires writing multi-agent communication logic yourself."** We already have it: label transitions (`ready_for_dev` → `ready_for_test` → `shipped` → `verified`) ARE the communication protocol. Issues move through states, scripts respond to labels. It's not a mailbox, but it doesn't need to be.

## Net Assessment

The screenshot is useful as a **validation** of design decisions auto-claude already made, not as a decision guide. The one actionable insight: **take the orphan/cost/failure warnings seriously when implementing V2's parallel workers.**
