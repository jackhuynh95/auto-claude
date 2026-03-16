# Research 01: Loop Guardrails — Audit of What Exists vs What's Missing

## Current Guardrails (Already Implemented)

### 1. Lock File (looper.sh:94-106)
- PID-based lock at `logs/.looper.lock`
- Detects stale locks from dead processes
- Prevents concurrent looper runs
- **Gap**: only guards `looper.sh`, not parallel workers

### 2. Iteration Limits
- `fix-issue.sh`: `MAX_RETRIES` (default 3) for debug→fix→test cycles
- `looper.sh`: `LIMIT` flag (default 10) caps issues per label scan
- **Gap**: no wall-clock timeout. A single issue can run forever if Claude CLI hangs.

### 3. Build Validation Gate (fix-issue.sh:369-394)
- After each fix attempt, runs `npm run build` / `cargo build` / `go build`
- Checks output for "error|failed|exception"
- Feeds errors back into next fix attempt
- **Gap**: regex-based error detection is brittle. `grep -qi "error"` matches "errorHandler" in success output.

### 4. E2E False-Positive Detection (verify-issue.sh:181-184)
- Checks if agent did "code analysis only" instead of actual browser tests
- Regex: `not run|no browser execution|code review only|...`
- **This is smart** — catches a real failure mode where Claude describes tests instead of running them.

### 5. Model Routing (fix-issue.sh:84-94, ship-issue.sh:76-82)
- Sonnet for execution tasks (cheaper, faster)
- Opus for reasoning tasks (debug analysis, planning, design review)
- `--hard` flag escalates to Opus for complex bugs
- Label-driven: "hard" label auto-adds `--hard` flag

### 6. Dirty Tree Protection
- Both scripts stash uncommitted changes before starting
- `looper.sh` does `git checkout main` between issues

## Missing Guardrails (Priority-Ordered)

### P0: Wall-Clock Timeout
**Problem**: If Claude CLI hangs or enters an infinite conversation loop, the worker runs forever. `MAX_RETRIES` only limits fix cycles, not total time.

**Fix**: Wrap `claude -p` calls in `timeout`:
```bash
timeout 600 claude -p "$prompt" ... || { warn "Claude timed out after 10m"; return 1; }
```

Or at the script level:
```bash
# In looper.sh, wrap each dispatch
timeout 1800 bash "${SCRIPT_DIR}/${script}" "$num" $issue_flags
```

### P1: Repeated Output Detection (Spin Detection)
**Problem**: Claude sometimes produces the same output/fix across retries. The loop retries 3 times with the same failing approach.

**Fix**: Hash each `run_claude` output. If hash matches previous attempt, break early:
```bash
local output_hash=$(echo "$output" | md5 -q)
if [[ "$output_hash" == "$LAST_OUTPUT_HASH" ]]; then
    warn "Identical output detected — breaking retry loop"
    break
fi
LAST_OUTPUT_HASH="$output_hash"
```

### P2: Cost Tracking
**Problem**: No visibility into API spend per issue or per run. An overnight run with Opus could burn $50+ without anyone noticing.

**Fix**: Claude CLI supports `--output-format json` which includes token counts. Parse and accumulate:
```bash
local tokens=$(echo "$output" | jq -r '.usage.total_tokens // 0')
TOTAL_TOKENS=$((TOTAL_TOKENS + tokens))
```

Log per-issue and per-run totals. Alert if over threshold.

### P3: Git Conflict Detection
**Problem**: If two sequential issues modify overlapping files, the second PR may have merge conflicts with main (since the first PR hasn't been merged yet).

**Fix**: After `step_4_commit`, check `git diff --name-only main...HEAD` against a shared file list. Warn on overlap. Not a blocker for serial mode, but critical for parallel.

### P4: Health Recovery
**Problem**: `verify-issue.sh` checks `localhost:9000/health` and skips if down. But it doesn't try to restart services.

**Fix**: This should remain skip-and-warn for now. Auto-restarting services is a can of worms. But log it clearly so the morning profile summary surfaces it.

## Guardrails NOT Worth Adding

| Idea | Why Skip |
|---|---|
| Rate-limit detection on Claude API | Claude CLI already handles retries with backoff. Adding a wrapper would duplicate logic. |
| Per-worker log isolation | Already exists — each script creates its own log file with timestamp. |
| Structured JSON logs | Overkill. The `.log → .md` transform in `looper.sh` already makes logs readable. JSON would hurt human debugging. |
