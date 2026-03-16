# Research 01: Loop Guardrails To Borrow First

## Source Direction

Primary inspiration: `from-groq/ralph-claude-code`

## Guardrails Worth Borrowing

### 1. Dual-condition exit gates

The loop should not stop only because the model says it is done.

It should require both:

- a natural completion signal from the agent
- an explicit system-level validation that the task is actually complete

## 2. Circuit breakers

The loop needs protection against self-correction spirals and repeated failures.

Useful breaker signals:

- too many iterations
- repeated identical outputs
- repeated command failures
- no meaningful state change across cycles

## 3. Rate-limit handling

The wrapper should recognize API or CLI rate limits, then pause and resume cleanly instead of failing hard.

## 4. Live tmux visibility

If we run long-lived agents, `tmux` gives us a lightweight way to:

- inspect live output
- attach/detach sessions
- keep logs readable without blocking the main terminal

## Why This Matters

These are the pieces most likely to make the system safe for unattended runs.

Without them, multi-agent orchestration becomes fragile.

## Candidate v1 Scope

- loop runner
- validation gate
- iteration counter and breaker logic
- retry and cooldown behavior
- structured logs
- optional `tmux` session support

## Discussion Questions

- Which breaker signals are mandatory for v1?
- Should `tmux` be required or optional?
- Do we log per run, per issue, or per worker?
