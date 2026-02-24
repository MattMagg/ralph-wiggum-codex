# Runbook

## Primary Usage (Skill Invocation)

Use this skill via `$ralph-wiggum-codex` and let Codex orchestrate the loop.

Recommended invocation payload:

- Objective
- Working directory
- Validation commands
- Progress scope (`--progress-scope`) for meaningful edit detection
- Runtime caps (`max-iterations`, `max-stagnant-iterations`, timeout settings)
- Completion promise only if compatibility mode is needed (deprecated)

## Loop Inputs

Under `<cwd>/.codex/ralph-loop/` maintain:

- `objective.md`: canonical task objective, reloaded every iteration
- `feedback.md`: operator steering notes, reloaded every iteration

## Script Command (Advanced / Direct)

```bash
~/.codex/skills/ralph-wiggum-codex/scripts/ralph-loop-codex.sh \
  --cwd /repo \
  --objective-file /repo/.codex/ralph-loop/objective.md \
  --feedback-file /repo/.codex/ralph-loop/feedback.md \
  --source-of-truth docs/tasks/task.md \
  --completion-promise "DONE" \
  --max-iterations 40 \
  --max-stagnant-iterations 6 \
  --progress-scope "src/" \
  --idle-timeout-seconds 900 \
  --hard-timeout-seconds 7200 \
  --timeout-retries 1 \
  --validate-cmd "npm run lint" \
  --validate-cmd "npm run test"
```

## Resume

```bash
~/.codex/skills/ralph-wiggum-codex/scripts/ralph-loop-codex.sh \
  --cwd /repo \
  --resume
```

## Manual Stop

```bash
touch /repo/.codex/ralph-loop/STOP
```

## Observability And Triage

Review these files first:

- `.codex/ralph-loop/events.log`
- `.codex/ralph-loop/run-summary.md`
- `.codex/ralph-loop/iteration-history.md`
- `.codex/ralph-loop/completion-schema.json`
- `.codex/ralph-loop/codex/iteration-<n>-attempt-<m>.jsonl`
- `.codex/ralph-loop/auto-feedback.md`
- `.codex/ralph-loop/validation/iteration-*/`

If progress stalls, update `feedback.md` with concrete corrective direction and continue with `--resume`.

## Runtime Notes

- `--max-stagnant-iterations` stops repeated no-progress output loops.
- `--progress-scope` plus `no_change_justification` blocks no-op iterations.
- `--idle-timeout-seconds` and `--hard-timeout-seconds` prevent hung `codex exec` runs.
- `--timeout-retries` retries timeout-killed attempts (default: 1).
- `--reclaim-stale-lock` force-recovers malformed lock metadata.
- `--sleep-seconds` can reduce thrashing for external or rate-limited systems.
- Use finite `--max-iterations` for unattended runs unless intentionally unbounded.
