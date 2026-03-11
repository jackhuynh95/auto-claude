# Issue 07: Model Routing — Right Model for Right Task

## Summary

Route each task to the appropriate Claude model to save tokens. Thinking-heavy tasks use Opus, execution tasks use Sonnet.

## Motivation

Opus is expensive but great for reasoning. Sonnet is cheaper and fast enough for code execution. The looper/scripts should pick the right model per task type.

## Model Mapping

| Task | Model | Why |
|------|-------|-----|
| `/plan` | Opus | Needs deep reasoning, architecture decisions |
| `/debug` | Opus | Root cause analysis requires thinking |
| `/brainstorm` | Opus | Creative exploration, tradeoff analysis |
| `/frontend-design` | Opus | Design judgment, UI/UX reasoning |
| `/code` | Sonnet | Straightforward implementation |
| `/fix` | Sonnet | Apply known patterns, iterate fast |
| `/fix:hard` | Opus | Complex bugs need deeper reasoning |
| `/cook` | Sonnet | Implementation from existing plan |
| `e2e-test` | Sonnet | Scripted browser steps, no heavy thinking |

## Implementation

### Claude CLI Flag

```bash
# Default (Opus)
claude -p "prompt"

# Switch to Sonnet
claude -p "prompt" --model sonnet
# or
claude /model sonnet
```

### In fix-issue.sh

```bash
# Determine model based on task
if [[ "$HARD_MODE" == "true" ]]; then
    MODEL_FLAG=""  # default = Opus for hard bugs
else
    MODEL_FLAG="--model sonnet"  # Sonnet for standard fixes
fi

# In run_claude():
claude -p "$prompt" $MODEL_FLAG $flags --continue --output-format text
```

### In looper.sh

```bash
# Model selected per pipeline stage
case "$STAGE" in
    ready_for_dev)
        # Standard fix = Sonnet, hard fix = Opus
        MODEL="sonnet"
        [[ "$FLAGS" == *"--hard"* ]] && MODEL=""
        ;;
    ready_for_test)
        # E2E = Sonnet (scripted steps)
        MODEL="sonnet"
        ;;
esac
```

## Cost Impact

Rough estimate per issue:
- All Opus: ~$0.50–$2.00/issue
- Sonnet for fix + Opus for plan/debug: ~$0.15–$0.60/issue
- ~60-70% token savings on execution-heavy tasks

## Acceptance Criteria

- [ ] `fix-issue.sh` uses `--model sonnet` by default, Opus for `--hard`
- [ ] `looper.sh` passes model flag based on pipeline stage
- [ ] Model choice logged for cost tracking
- [ ] Can override with `--model opus` flag if needed
