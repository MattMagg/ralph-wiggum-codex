# Ralph Wiggum Codex Skill

Ralph-style long-running autonomous refinement for Codex, packaged as an installable skill.

`ralph-wiggum-codex` is a Codex skill for iterative coding loops that continuously refine work until validation passes and completion criteria are met.

## What This Is

This is not a Claude plugin port that relies on `.claude-plugin` hooks. It is a Codex-native skill with:
- `SKILL.md` instructions for skill invocation
- optional `agents/openai.yaml` metadata and invocation policy
- a deterministic loop runner script used by the skill for reliable long runs

## Core Capabilities

- Multi-iteration implement -> validate -> refine loops
- Deterministic completion via `codex exec --output-schema`
- Dynamic objective reloading (`--objective-file`)
- Live steering feedback reloading (`--feedback-file`)
- Auto corrective feedback generation on failures
- Iteration memory (`iteration-history.md`) fed back into future iterations
- Stagnation detection (`--max-stagnant-iterations`)
- Scoped progress gating (`--progress-scope`) to block no-op iterations
- Watchdog timeouts with controlled retries (`--idle-timeout-seconds`, `--hard-timeout-seconds`, `--timeout-retries`)
- Resume support and stale-lock recovery with metadata (`--reclaim-stale-lock`)

## Install

### Option 1: Codex Skill Installer (recommended)

```bash
python3 ~/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py \
  --repo MattMagg/ralph-wiggum-codex \
  --path skills/ralph-wiggum-codex
```

Restart Codex after install.

### Option 2: Manual Install

```bash
mkdir -p ~/.codex/skills
cp -R skills/ralph-wiggum-codex ~/.codex/skills/
```

Restart Codex after install.

## Use It As A Skill (Primary)

This skill is configured for explicit invocation (`allow_implicit_invocation: false`), so call it directly:

```text
$ralph-wiggum-codex
Run this in /path/to/repo.
Objective: implement X with tests.
Validation:
- npm run lint
- npm run test
Completion promise (compatibility mode): DONE
Max iterations: 40
Max stagnant iterations: 6
```

The skill will set up and run the loop under `.codex/ralph-loop/`.

## Advanced: Run The Engine Script Directly

```bash
~/.codex/skills/ralph-wiggum-codex/scripts/ralph-loop-codex.sh \
  --cwd /path/to/repo \
  --objective-file /path/to/repo/.codex/ralph-loop/objective.md \
  --feedback-file /path/to/repo/.codex/ralph-loop/feedback.md \
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

`--completion-promise` is still supported for compatibility but deprecated. Completion is accepted from schema-conformant JSON output (`status=COMPLETE`) plus passing validations.

Resume:

```bash
~/.codex/skills/ralph-wiggum-codex/scripts/ralph-loop-codex.sh \
  --cwd /path/to/repo \
  --resume
```

Stop:

```bash
touch /path/to/repo/.codex/ralph-loop/STOP
```

## Final Message JSON Contract

Each iteration asks Codex to emit exactly one JSON object conforming to `.codex/ralph-loop/completion-schema.json`:

- `status`: `IN_PROGRESS`, `BLOCKED`, or `COMPLETE`
- `evidence`: non-empty array of concrete command/result evidence
- `next_step`: one highest-impact next step
- `no_change_justification`: optional explanation when no scoped files changed
- `completion_promise`: optional compatibility field (checked when `--completion-promise` is configured)

## Run Artifacts

- `.codex/ralph-loop/state.env`
- `.codex/ralph-loop/events.log`
- `.codex/ralph-loop/completion-schema.json`
- `.codex/ralph-loop/iteration-history.md`
- `.codex/ralph-loop/feedback.md`
- `.codex/ralph-loop/auto-feedback.md`
- `.codex/ralph-loop/last-message.txt`
- `.codex/ralph-loop/run-summary.md`
- `.codex/ralph-loop/validation/`
- `.codex/ralph-loop/codex/iteration-<n>-attempt-<m>.jsonl`
- `.codex/ralph-loop/.lock/meta.env` (while active)

## Repo Structure

```text
skills/ralph-wiggum-codex/
  SKILL.md
  agents/openai.yaml
  scripts/ralph-loop-codex.sh
  references/
    harness-principles.md
    runbook.md
```

## CI

This repo runs:
- Bash syntax check for the loop runner
- Smoke tests in `tests/smoke.sh`

## Search Keywords

Codex skill, autonomous coding loop, iterative coding agent, long-running coding workflow, agentic refinement loop, Ralph loop Codex, coding harness.

## License

MIT
