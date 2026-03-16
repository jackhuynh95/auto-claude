# Research Overview

This folder groups future-direction research notes for the repo.

## Topics

- [Swarm Direction](./swarm-direction/research-00-swarm-direction.md)
- [Loop Guardrails](./loop-guardrails/research-01-loop-guardrails.md)
- [Swarm Orchestration](./swarm-orchestration/research-02-swarm-orchestration.md)
- [Bash Architecture Sketch](./bash-architecture-sketch/research-03-bash-architecture-sketch.md)

## Main Takeaway

The current recommendation is:

1. build a safe, reliable looper first
2. add model routing second
3. expand into a real swarm after the foundation is stable

In short:

- `agent-swarm` provides the origin idea
- `ralph-claude-code` provides the stronger v1 foundation
- this repo can evolve by combining both approaches in a Bash-first orchestrator
