# Research 03: Bash Architecture Sketch

## Goal

Sketch the future direction for this repo as a Bash-first AI orchestrator.

## Proposed Flow

```text
main loop
  -> validate task state
  -> choose worker type
  -> choose model/CLI
  -> execute worker
  -> inspect result
  -> decide: continue, retry, pause, or stop
```

## Candidate Components

- `looper.sh` or equivalent main commander
- `validate-exit.sh` for explicit completion checks
- `circuit-breaker.sh` for loop safety rules
- `spawn-worker.sh` for CLI/model abstraction
- `swarm-commander.sh` for future parallel routing
- `logs/` for per-run and per-worker output

## Design Principles

- Bash-first and lightweight
- model-agnostic where possible
- safe for unattended execution
- easy to inspect and debug locally
- modular enough to upgrade into a swarm later

## Near-term Recommendation

Build the minimal stable loop first, then add:

1. model routing
2. worker abstraction
3. tmux-backed swarm execution

## Discussion Questions

- Should Bash remain the main orchestration layer long-term?
- Where do we draw the line before moving logic into Python or Node helpers?
- What should count as the first real milestone for the future swarm system?
