# Research 00: Swarm Direction

## Context

This note captures the main takeaway from the Gemini discussion so we can review it later with a coworker.

## Core Recommendation

Build the system in two layers:

1. Start with a strong Bash-first loop engine inspired by `from-groq/ralph-claude-code`
2. Add multi-model swarm orchestration ideas inspired by `agent-swarm`

The recommendation is not to build the swarm first. The recommendation is to make the single-agent loop safe and reliable first, then expand it into a swarm.

## Why

- A swarm without guardrails can spin forever, crash, or waste API credits
- A stable loop gives us a better base for automation, retries, and unattended runs
- Model diversity only helps once the orchestration layer is already dependable

## Practical Interpretation For This Repo

- `agent-swarm` is the origin idea
- `ralph-claude-code` is the stronger foundation for v1
- The future goal for this repo is a Bash-first orchestrator that combines both

## Discussion Questions

- Do we agree that loop stability should be the first milestone before swarm features?
- Do we want v1 to stay single-agent but multi-model aware?
- What is the smallest useful version we can ship before adding parallel workers?
