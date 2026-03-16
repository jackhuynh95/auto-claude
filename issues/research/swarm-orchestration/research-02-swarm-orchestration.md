# Research 02: Swarm Orchestration After The Foundation

## Source Direction

Primary inspiration: `agent-swarm`

## Ideas Worth Borrowing

### 1. CLI agnosticism

The orchestrator should not depend on a single model vendor.

Instead, it should be able to route work to different CLIs, for example:

- Claude CLI
- Gemini CLI
- Codex CLI

## 2. Worker specialization

Different models can be assigned to different job types.

Example:

- reasoning/planning -> stronger reasoning model
- code execution -> faster cheaper model
- research/scraping -> model or toolchain best suited for wide exploration

## 3. Parallel task routing

Once the foundation is safe, the orchestrator can spawn multiple workers and coordinate them through Bash plus `tmux`.

## Suggested Layering

### Phase 1

Single-agent, safe loop, strong logs, exit gates, breaker logic

### Phase 2

Add model wrapper so one interface can call different CLIs

### Phase 3

Add swarm coordination:

- multiple workers
- task routing
- per-worker logs
- shared result collection

## Important Constraint

The swarm should be an extension of a stable looper, not a replacement for it.

## Discussion Questions

- Do we want model routing before true parallel swarm execution?
- Which worker roles are useful first: planner, coder, reviewer, researcher?
- How much coordination should live in Bash vs helper scripts?
